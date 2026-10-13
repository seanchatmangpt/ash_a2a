defmodule AshA2APlugAuthorizeRefusalReceiptTest.Converse do
  @moduledoc """
  Real fixture resource, private to this lane (L153), for the
  plug-authorize refusal-receipt court.
  """

  use Ash.Resource,
    domain: AshA2APlugAuthorizeRefusalReceiptTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read])

    action :converse, :map do
      argument(:say, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{say: input.arguments.say}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2APlugAuthorizeRefusalReceiptTest.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2APlugAuthorizeRefusalReceiptTest.Converse)
  end
end

defmodule AshA2APlugAuthorizeRefusalReceiptTest.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer serving the fixture resource (inline
  execution, no auth requirement -- the authorize_task callback is the
  refusal surface under court).
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2APlugAuthorizeRefusalReceiptTest.Converse,
    name: "plug_authorize_refusal_agent",
    execution: [mode: :inline]
end

defmodule AshA2APlugAuthorizeRefusalReceiptTest do
  @moduledoc """
  L153 courts: every `AshA2A.Protocol.Plug` authorize rejection
  (`authorize_task/authorize_task_list`) commits a refusal receipt over the
  refused task/action identity (`AshA2A.Semantic.Refusal.commit/2`), without
  any change to the wire response (still the same -32001 `TASK_NOT_FOUND`
  shape). Mirrors the owner-scope court's real-transport pattern: real agent
  GenServer, real JSON-RPC over `Plug.Test` conns, zero mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Semantic.Refusal

  @event [:ash_a2a, :protocol, :plug, :authorize_refused]

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"plug_authorize_refusal_#{uniq}"

    start_supervised!({AshA2APlugAuthorizeRefusalReceiptTest.Agent, name: agent})

    # Authorizer denies every task-scoped operation (the court's refusal
    # surface); message/send is not task-scoped, so task creation works.
    plug =
      TransportPlug.init(
        agent: agent,
        base_url: "http://x/a2a",
        authorize_task: fn _operation, _task, _context -> :deny end
      )

    :ok =
      :telemetry.attach(
        {:l153_authorize_refused, uniq},
        @event,
        &__MODULE__.handle_event/4,
        %{test: self()}
      )

    on_exit(fn -> :telemetry.detach({:l153_authorize_refused, uniq}) end)

    %{agent: agent, plug: plug}
  end

  def handle_event(@event, _measurements, meta, %{test: test}), do: send(test, {:refused, meta})
  def handle_event(_other, _m, _meta, _), do: :ok

  # -- wire helpers ------------------------------------------------------------

  defp rpc(%{agent_card_path: _} = protocol_plug_opts, method, params) do
    AshA2A.Protocol.Plug.call(conn_for(method, params), protocol_plug_opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp rpc(plug, method, params) do
    TransportPlug.call(conn_for(method, params), plug)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp conn_for(method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp skill_message do
    alias AshA2A.Protocol.{JSON, Message, Part}
    parts = [Part.Data.new(%{"say" => "hello"})]
    msg = struct(Message.new_user(parts), metadata: %{"skill" => "converse"})
    {:ok, encoded} = JSON.encode(msg)
    %{"message" => encoded}
  end

  defp create_task_id(plug) do
    assert %{"result" => res} = rpc(plug, "message/send", skill_message())
    get_in(res, ["task", "id"]) || res["id"]
  end

  test "denied tasks/get returns the unchanged -32001 wire shape AND commits a receipt over the refused subject",
       %{plug: plug} do
    %{"result" => res} = rpc(plug, "message/send", skill_message())
    task_id = get_in(res, ["task", "id"]) || res["id"]

    assert %{"error" => %{"code" => -32_001}} = rpc(plug, "tasks/get", %{"id" => task_id})

    assert_receive {:refused, %{operation: :get, task_id: ^task_id, refusal: refusal}}, 1_000
    assert %Refusal{class: :refused_authority, code: :denied, receipt: receipt} = refusal
    assert is_binary(receipt) and byte_size(receipt) == 32

    assert receipt ==
             Refusal.receipt(
               :refused_authority,
               :denied,
               :protocol_plug_authorize,
               {:task, task_id}
             )
  end

  test "receipt is deterministic per subject and subject-bound (diverges across tasks)", %{
    plug: plug
  } do
    %{"result" => res} = rpc(plug, "message/send", skill_message())
    a_id = get_in(res, ["task", "id"]) || res["id"]
    %{"result" => res} = rpc(plug, "message/send", skill_message())
    b_id = get_in(res, ["task", "id"]) || res["id"]

    assert %{"error" => %{"code" => -32_001}} = rpc(plug, "tasks/get", %{"id" => a_id})
    assert %{"error" => %{"code" => -32_001}} = rpc(plug, "tasks/get", %{"id" => a_id})
    assert %{"error" => %{"code" => -32_001}} = rpc(plug, "tasks/get", %{"id" => b_id})

    assert_receive {:refused, %{task_id: ^a_id, refusal: a1}}, 1_000
    assert_receive {:refused, %{task_id: ^a_id, refusal: a2}}, 1_000
    assert_receive {:refused, %{task_id: ^b_id, refusal: b}}, 1_000

    assert a1.receipt == a2.receipt
    assert a1.receipt != b.receipt
  end

  test "denied tasks/list filtering commits one receipt per refused task", %{agent: agent} do
    # `tasks/list` is owner-scoped in the wrapper transport, so this court
    # drives the vendored `AshA2A.Protocol.Plug` directly (its `handle_list`
    # is where `authorize_task_list` runs).
    plug =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        authorize_task: fn _op, _task, _ctx -> :deny end
      )

    a_id = create_task_id(plug)
    b_id = create_task_id(plug)

    result = rpc(plug, "tasks/list", %{})
    assert %{"result" => %{"tasks" => [], "totalSize" => 0}} = result

    assert_receive {:refused, %{operation: :list, task_id: t1}}, 1_000
    assert_receive {:refused, %{operation: :list, task_id: t2}}, 1_000
    assert Enum.sort([t1, t2]) == Enum.sort([a_id, b_id])
  end

  test "explicit authorizer error also commits a receipt (wire response untouched)", %{
    agent: agent
  } do
    plug =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        authorize_task: fn _op, _task, _ctx ->
          {:error, AshA2A.Protocol.JSONRPC.Error.internal_error("policy engine down")}
        end
      )

    %{"result" => res} = rpc(plug, "message/send", skill_message())
    task_id = get_in(res, ["task", "id"]) || res["id"]

    assert %{"error" => %{"code" => -32_603}} = rpc(plug, "tasks/get", %{"id" => task_id})

    assert_receive {:refused, %{task_id: ^task_id, refusal: refusal}}, 1_000
    assert is_binary(refusal.receipt) and byte_size(refusal.receipt) == 32
  end
end
