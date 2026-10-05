defmodule AshA2AV1ListDecodeTest.Converse do
  @moduledoc """
  Real fixture resource, private to lane Z9, for the ListTasks envelope
  decode court (`AshA2AV1ListDecodeTest`). Same shape as the owner-scope
  court's fixture: one generic `:converse` action so a `message/send` runs a
  real skill and lands a real task in the real agent's state.
  """

  use Ash.Resource,
    domain: AshA2AV1ListDecodeTest.Domain,
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

defmodule AshA2AV1ListDecodeTest.Domain do
  @moduledoc "Real fixture domain for `AshA2AV1ListDecodeTest.Converse`."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2AV1ListDecodeTest.Converse)
  end
end

defmodule AshA2AV1ListDecodeTest.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer (transport runtime: owner-keyed tasks) used
  to produce real server-side page envelopes.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2AV1ListDecodeTest.Converse,
    name: "v1_list_decode_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule AshA2AV1ListDecodeTest do
  @moduledoc """
  Lane Z9: ListTasks envelope codec decode (`AshA2A.Protocol.JSON.
  decode_list_result/1`).

  The `tasks/list` page envelope (`{"tasks": [...], "totalSize", "pageSize",
  "nextPageToken"}`) previously had no codec decode path. This court drives a
  REAL agent + owner-scoped list through `AshA2A.Transport.Plug` (no mocks),
  then proves:

    * the wire envelope a real server produced decodes into the runtime's
      atom-keyed page map (task structs via the ordinary task decode path);
    * round-trip parity: `decode_list_result/1` of an encoded page equals
      `AshA2A.Transport.Plug.handle_list/2`'s runtime map;
    * malformed envelopes are typed refusals under the codec's
      `{:error, {:missing_field, _}}` convention;
    * the empty-page shape decodes;
    * the spec's ListTasksSuccess example shape decodes (embedded here — the
      frozen spec corpus file is lane X6's and is intentionally untouched).

  Zero mocks: real `AshA2A.Agent` GenServer, real bearer auth middleware,
  real plugs, real wire JSON.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{JSON, Message, Part}
  alias AshA2A.Transport.Plug, as: TransportPlug
  alias AshA2A.Transport.Principal

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  def verify("bearer", token, _conn), do: {:ok, %{sub: token}}

  setup do
    %{ctx: context()}
  end

  # -- real wire helpers -------------------------------------------------------

  defp rpc(ctx, user, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
      |> AshA2A.Protocol.Plug.Auth.call(ctx.auth)
      |> TransportPlug.call(ctx.plug)

    refute conn.halted
    Jason.decode!(conn.resp_body)
  end

  # One real `message/send` turn carrying the structured `say` argument in a
  # Data part (how the dispatcher feeds generic-action arguments); returns the
  # wire task id.
  defp create_task(ctx, user, say) do
    msg =
      struct(
        Message.new_user([Part.Data.new(%{"say" => say})]),
        metadata: %{"skill" => "converse"}
      )

    {:ok, encoded} = JSON.encode(msg)

    assert %{"result" => result} = rpc(ctx, user, "message/send", %{"message" => encoded})

    task = get_in(result, ["task"]) || result
    assert is_binary(task["id"])
    task["id"]
  end

  # -- real decode of a real server-produced envelope ---------------------------

  test "wire envelope from a real owner-scoped list decodes to the runtime page map", %{ctx: ctx} do
    id1 = create_task(ctx, "alice", "one")
    id2 = create_task(ctx, "alice", "two")

    assert %{"result" => page} = rpc(ctx, "alice", "tasks/list", %{})
    assert %{"tasks" => wire_tasks, "totalSize" => 2, "pageSize" => 2, "nextPageToken" => ""} = page
    assert length(wire_tasks) == 2
    assert MapSet.new(wire_tasks, & &1["id"]) == MapSet.new([id1, id2])

    assert {:ok, decoded} = JSON.decode_list_result(page)
    assert %{tasks: tasks, total_size: 2, page_size: 2, next_page_token: ""} = decoded
    assert length(tasks) == 2
    assert Enum.all?(tasks, &match?(%AshA2A.Protocol.Task{}, &1))
    assert MapSet.new(tasks, & &1.id) == MapSet.new([id1, id2])

    # Bob's list is owner-scoped: an empty page, and it decodes too.
    assert %{"result" => bob_page} = rpc(ctx, "bob", "tasks/list", %{})
    assert bob_page["totalSize"] == 0
    assert {:ok, %{tasks: [], total_size: 0, page_size: 0, next_page_token: ""}} =
             JSON.decode_list_result(bob_page)
  end

  # -- round-trip parity ---------------------------------------------------------

  test "decode_list_result of an encoded page equals the runtime handle_list map", %{ctx: ctx} do
    create_task(ctx, "carol", "parity")
    principal = Principal.key(%{sub: "carol"})

    assert {:ok, runtime_page} =
             AshA2A.Transport.Plug.handle_list(%{}, %{agent: ctx.agent, principal: principal})

    assert %{tasks: runtime_tasks, total_size: 1, page_size: 1, next_page_token: ""} =
             runtime_page

    # Encode exactly as the server's JSON-RPC binding does
    # (AshA2A.Protocol.JSONRPC encode_list_result shape).
    wire = %{
      "tasks" => Enum.map(runtime_tasks, &JSON.encode!/1),
      "totalSize" => runtime_page.total_size,
      "pageSize" => runtime_page.page_size,
      "nextPageToken" => runtime_page.next_page_token
    }

    assert {:ok, ^runtime_page} = JSON.decode_list_result(wire)
  end

  # -- malformed envelopes: typed refusals ----------------------------------------

  test "missing tasks member is a typed refusal" do
    assert {:error, {:missing_field, "tasks"}} =
             JSON.decode_list_result(%{"totalSize" => 0})

    assert {:error, {:missing_field, "tasks"}} = JSON.decode_list_result(%{})
    assert {:error, {:missing_field, "tasks"}} = JSON.decode_list_result("not a map")
    assert {:error, {:missing_field, "tasks"}} = JSON.decode_list_result(nil)
  end

  test "non-list tasks member is a typed refusal" do
    assert {:error, {:missing_field, "tasks"}} =
             JSON.decode_list_result(%{"tasks" => "t1"})
  end

  test "malformed task entry propagates the task decoder's typed refusal" do
    assert {:error, {:missing_field, "status"}} =
             JSON.decode_list_result(%{"tasks" => [%{"id" => "t1"}]})

    assert {:error, {:missing_field, "id"}} =
             JSON.decode_list_result(%{"tasks" => [%{"status" => %{"state" => "TASK_STATE_WORKING"}}]})
  end

  test "wrongly-typed totalSize/pageSize/nextPageToken are typed refusals" do
    base = fn value -> %{"tasks" => [], "totalSize" => value} end

    assert {:error, {:missing_field, "totalSize"}} =
             JSON.decode_list_result(base.("5"))

    assert {:error, {:missing_field, "pageSize"}} =
             JSON.decode_list_result(%{"tasks" => [], "pageSize" => 1.5})

    assert {:error, {:missing_field, "nextPageToken"}} =
             JSON.decode_list_result(%{"tasks" => [], "nextPageToken" => 7})
  end

  # -- empty page / absent optionals ------------------------------------------------

  test "empty page shape decodes" do
    assert {:ok, %{tasks: [], total_size: 0, page_size: 0, next_page_token: ""}} =
             JSON.decode_list_result(%{
               "tasks" => [],
               "totalSize" => 0,
               "pageSize" => 0,
               "nextPageToken" => ""
             })
  end

  test "absent totalSize/pageSize/nextPageToken decode as nils" do
    assert {:ok, %{tasks: [], total_size: nil, page_size: nil, next_page_token: nil}} =
             JSON.decode_list_result(%{"tasks" => []})
  end

  # -- spec ListTasksSuccess example ---------------------------------------------------

  @spec_page %{
    "tasks" => [
      %{
        "id" => "task-8b2c",
        "contextId" => "ctx-3f9a",
        "status" => %{
          "state" => "TASK_STATE_WORKING",
          "timestamp" => "2025-05-03T12:00:00.000Z"
        }
      },
      %{
        "id" => "task-1d05",
        "contextId" => "ctx-3f9a",
        "status" => %{
          "state" => "TASK_STATE_COMPLETED",
          "timestamp" => "2025-05-03T11:30:00.000Z"
        }
      }
    ],
    "totalSize" => 12,
    "pageSize" => 2,
    "nextPageToken" => "task-1d05"
  }

  test "spec ListTasksSuccess example shape decodes (corpus file untouched)" do
    # The frozen spec corpus (priv/a2a_v1_spec_corpus/v1_spec_examples.json)
    # and its test are lane X6's; the ListTasksSuccess page has no entry
    # there, so the spec example shape is pinned here instead.
    assert {:ok, page} = JSON.decode_list_result(@spec_page)
    assert %{tasks: [first, second], total_size: 12, page_size: 2, next_page_token: "task-1d05"} =
             page

    assert %AshA2A.Protocol.Task{id: "task-8b2c", status: %{state: :working}} = first
    assert %AshA2A.Protocol.Task{id: "task-1d05", status: %{state: :completed}} = second
  end

  # -- plumbing -----------------------------------------------------------------------

  defp context do
    uniq = System.unique_integer([:positive])
    agent = :"v1_list_decode_#{uniq}"

    start_supervised!({AshA2AV1ListDecodeTest.Agent, name: agent})

    auth = AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3)

    %{agent: agent, auth: auth, plug: TransportPlug.init(agent: agent, base_url: "http://x/a2a")}
  end
end