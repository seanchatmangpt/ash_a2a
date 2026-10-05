# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1ElicitationTest.Note do
  @moduledoc """
  Real fixture resource: one `:create` action requiring `text` — the same
  park-on-missing-argument shape the repo's demo walks (missing argument ->
  `TASK_STATE_INPUT_REQUIRED`), here driven through the formal elicitation
  contract instead of an untyped park.
  """

  use Ash.Resource,
    domain: AshA2A.V1ElicitationTest.HomeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :create, :map do
      argument(:text, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{text: input.arguments.text, recorded: true}}
      end)
    end
  end

  a2a do
    skill(:create, :create, consequence: :observe)
  end
end

defmodule AshA2A.V1ElicitationTest.HomeDomain do
  @moduledoc "Real fixture domain for the note resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1ElicitationTest.Note)
  end
end

defmodule AshA2A.V1ElicitationTest.ElicitAgent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer composing the `AshA2A.Elicitation` contract in
  its real `handle_message/2` — recover the pending elicitation from the
  task's own history, resume (validate BEFORE dispatch) or mint.

  This is the documented composition from `AshA2A.Elicitation`'s moduledoc,
  running through the real supervised GenServer, the real transport runtime
  (`AshA2A.Transport.Runtime` task state machine) and the real HTTPJSON
  binding end to end.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1ElicitationTest.HomeDomain,
    name: "v1_elicitation_agent",
    public_skills: [:create]

  @impl AshA2A.Protocol.Agent
  def handle_message(message, context) do
    history = Map.get(context, :history, [])

    case AshA2A.Elicitation.from_history(history) do
      {:ok, pending} ->
        case AshA2A.Elicitation.resume(pending, message) do
          {:ok, data} ->
            msg = %{message | parts: [AshA2A.Protocol.Part.Data.new(data)]}
            AshA2A.Agent.__dispatch__(@ash_a2a_resource_or_domain, msg, context, @ash_a2a_dispatch_opts)

          {:error, %AshA2A.Protocol.JSONRPC.Error{} = err} ->
            # Fail-closed: park with the typed error, never dispatch. The task
            # stays `:input_required` — a malformed response must not consume
            # the park.
            {:input_required,
             [
               AshA2A.Protocol.Part.Data.new(%{
                 "error" => AshA2A.Protocol.JSONRPC.Error.to_map(err),
                 "elicitationId" => pending.id
               })
             ]}

          {:error, {:elicitation_expired, _id} = expired} ->
            # Expiry: the standard error classifier maps a non-admission,
            # non-auth error to terminal `:failed` (task transitions per the
            # lifecycle).
            {:error, expired}
        end

      :error ->
        case AshA2A.Elicitation.request(@ash_a2a_resource_or_domain, :create,
               task_id: context.task_id,
               expires_in: Application.get_env(:ash_a2a, :v1_elicitation_expires_in)
             ) do
          {:ok, elicitation} -> AshA2A.Elicitation.reply(elicitation)
          {:error, _} = err -> {:error, err}
        end
    end
  end
end

defmodule AshA2A.V1ElicitationTest do
  @moduledoc """
  Court for the formal elicitation contract (ZACH lane ZD5): real agent, real
  transport, zero mocks.

  Elicit -> wrong-shape response refused with the typed schema error while the
  task stays parked `INPUT_REQUIRED` -> correct-shape response resumes the
  SAME task to `COMPLETED` — all over a real Bandit HTTP listener running the
  real `AshA2A.Transport.HTTPJSON` binding, against a real supervised
  `AshA2A.Agent` GenServer. Falsifier: this court green.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  @agent AshA2A.V1ElicitationTest.ElicitAgent

  setup do
    {_sup, _registry} = AgentSupervisorCase.start_supervised_agents!(__MODULE__, [@agent])

    plug_opts =
      AshA2A.Transport.HTTPJSON.init(
        agent: @agent,
        base_url: "http://127.0.0.1/fixture"
      )

    server = EphemeralHttp.start!({AshA2A.Transport.HTTPJSON, plug_opts})

    %{server: server}
  end

  test "elicit -> wrong shape refused with the schema error, task stays parked -> correct shape resumes to COMPLETED", %{
    server: server
  } do
    # Turn 1: elicit. The agent mints a schema-constrained input request and
    # parks the task.
    {:ok, %Req.Response{status: 200, body: %{"task" => parked}}} =
      post_message(server, user_message(%{}, %{"skill" => "create"}))

    assert parked["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

    elicitation = elicitation_part(parked)
    elicitation_id = elicitation["id"]
    assert is_binary(elicitation_id)
    assert elicitation["taskId"] == parked["id"]
    assert elicitation["mode"] == "form"

    # The requested schema is the REAL AshA2A.Schema projection of the action,
    # not a hand-written shape.
    schema = elicitation["requestedSchema"]
    assert schema["type"] == "object"
    assert schema["properties"]["text"] == %{"type" => "string"}
    assert schema["required"] == ["text"]

    # Turn 2 (wrong shape): a non-string `text`. Fail-closed: the response is
    # refused with the typed -32602 schema error and the task stays parked.
    {:ok, %Req.Response{status: 200, body: %{"task" => refused}}} =
      post_message(
        server,
        user_message(%{"text" => 123}, %{"skill" => "create", "elicitationId" => elicitation_id}, parked["id"])
      )

    assert refused["id"] == parked["id"]
    assert refused["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

    error = error_part(refused)
    assert error["code"] == -32_602
    assert error["message"] == "Invalid parameters"

    assert [info] = error["data"]
    assert info["reason"] == "INVALID_PARAMS"
    assert info["metadata"]["detail"] =~ "text"

    # The task is still parked, not consumed: tasks/get says INPUT_REQUIRED.
    {:ok, %Req.Response{status: 200, body: fetched}} = Req.get(url: task_url(server, parked["id"]))
    assert fetched["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

    # Turn 3 (correct shape): the SAME task id resumes through the real
    # transport runtime and the real Ash action runs.
    {:ok, %Req.Response{status: 200, body: %{"task" => resumed}}} =
      post_message(
        server,
        user_message(
          %{"text" => "hello elicitation"},
          %{"skill" => "create", "elicitationId" => elicitation_id},
          parked["id"]
        )
      )

    assert resumed["id"] == parked["id"]
    assert resumed["status"]["state"] == "TASK_STATE_COMPLETED"

    assert [artifact] = resumed["artifacts"]
    assert [part] = artifact["parts"]
    assert part["data"]["text"] == "hello elicitation"
    assert part["data"]["recorded"] == true

    # The resumed task is the persisted task, not a same-shaped new one.
    {:ok, %Req.Response{status: 200, body: fetched}} = Req.get(url: task_url(server, parked["id"]))
    assert fetched["status"]["state"] == "TASK_STATE_COMPLETED"
  end

  test "uncorrelated follow-up is refused -32602 and the task stays parked", %{server: server} do
    {:ok, %Req.Response{body: %{"task" => parked}}} =
      post_message(server, user_message(%{}, %{"skill" => "create"}))

    elicitation_id = elicitation_part(parked)["id"]

    # No elicitationId in the follow-up metadata: refused before the schema is
    # even consulted, task stays parked.
    {:ok, %Req.Response{body: %{"task" => refused}}} =
      post_message(
        server,
        user_message(%{"text" => "valid shape, wrong correlation"}, %{"skill" => "create"}, parked["id"])
      )

    assert refused["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
    error = error_part(refused)
    assert error["code"] == -32_602
    assert error["data"] |> hd() |> Map.fetch!("reason") == "INVALID_PARAMS"
    assert error["data"] |> hd() |> Map.fetch!("metadata") |> Map.fetch!("detail") =~ elicitation_id
  end

  test "expiry (configured) transitions the parked task to terminal FAILED through the lifecycle", %{
    server: server
  } do
    Application.put_env(:ash_a2a, :v1_elicitation_expires_in, 30)

    on_exit(fn -> Application.delete_env(:ash_a2a, :v1_elicitation_expires_in) end)

    {:ok, %Req.Response{body: %{"task" => parked}}} =
      post_message(server, user_message(%{}, %{"skill" => "create"}))

    elicitation_id = elicitation_part(parked)["id"]

    # Let the configured 30ms window lapse, then send a PERFECTLY VALID
    # response: expiry still fires — it is checked before the schema.
    Process.sleep(60)

    {:ok, %Req.Response{body: %{"task" => expired}}} =
      post_message(
        server,
        user_message(
          %{"text" => "arrived too late"},
          %{"skill" => "create", "elicitationId" => elicitation_id},
          parked["id"]
        )
      )

    assert expired["id"] == parked["id"]
    assert expired["status"]["state"] == "TASK_STATE_FAILED"

    # Terminal: a further follow-up is refused outright by the transport --
    # the AIP-193 envelope with the gRPC INVALID_ARGUMENT status, whose
    # details carry the runtime's typed -32602 ("task is terminal").
    {:ok, %Req.Response{status: 400, body: body}} =
      post_message(
        server,
        user_message(%{"text" => "again"}, %{"skill" => "create", "elicitationId" => elicitation_id}, parked["id"])
      )

    assert body["error"]["code"] == 400
    assert body["error"]["status"] == "INVALID_ARGUMENT"

    # The runtime's typed refusal rides in the ErrorInfo details.
    assert Enum.any?(
             body["error"]["details"] || [],
             &(&1["reason"] == "INVALID_PARAMS" and &1["metadata"]["detail"] =~ "terminal")
           )

    # tasks/get still reports the terminal state -- the lifecycle never went
    # backwards.
    {:ok, %Req.Response{status: 200, body: fetched}} = Req.get(url: task_url(server, parked["id"]))
    assert fetched["status"]["state"] == "TASK_STATE_FAILED"
  end

  test "default expiry is OFF: an elicitation without :expires_in never expires", %{server: server} do
    # No app env set -> `:expires_in` nil -> never expires. Turn 2 with a
    # deliberately malformed shape PROVES the refusal came from the schema
    # (parked, -32602), not from an expiry shortcut.
    {:ok, %Req.Response{body: %{"task" => parked}}} =
      post_message(server, user_message(%{}, %{"skill" => "create"}))

    elicitation_id = elicitation_part(parked)["id"]
    assert elicitation_part(parked)["expiresAt"] == nil

    {:ok, %Req.Response{body: %{"task" => refused}}} =
      post_message(
        server,
        user_message(%{"wrong" => "key"}, %{"skill" => "create", "elicitationId" => elicitation_id}, parked["id"])
      )

    assert refused["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
    assert error_part(refused)["code"] == -32_602
  end

  test " AshA2A.Elicitation.validate/2 enforces the restricted subset fail-closed" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "minLength" => 2},
        "age" => %{"type" => "integer", "minimum" => 18},
        "score" => %{"type" => "number", "maximum" => 100},
        "ok" => %{"type" => "boolean"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 1},
        "color" => %{"type" => "string", "enum" => ["red", "green"]}
      },
      "required" => ["text"],
      "additionalProperties" => false
    }

    assert AshA2A.Elicitation.validate(schema, %{"text" => "hi"}) == :ok

    {:error, violations} = AshA2A.Elicitation.validate(schema, %{"text" => "x"})
    assert %{"property" => "text", "error" => "shorter than minLength 2"} in violations

    {:error, violations} = AshA2A.Elicitation.validate(schema, %{})
    assert %{"property" => "text", "error" => "missing required property"} in violations

    {:error, violations} = AshA2A.Elicitation.validate(schema, %{"text" => "hi", "age" => "old"})
    assert %{"property" => "age", "error" => "expected integer, got string"} in violations

    {:error, violations} = AshA2A.Elicitation.validate(schema, %{"text" => "hi", "age" => 5})
    assert %{"property" => "age", "error" => "below minimum 18"} in violations

    {:error, violations} = AshA2A.Elicitation.validate(schema, %{"text" => "hi", "score" => 101.5})
    assert %{"property" => "score", "error" => "above maximum 100"} in violations

    {:error, violations} = AshA2A.Elicitation.validate(schema, %{"text" => "hi", "ok" => "yes"})
    assert %{"property" => "ok", "error" => "expected boolean, got string"} in violations

    {:error, violations} =
      AshA2A.Elicitation.validate(schema, %{"text" => "hi", "tags" => []})

    assert %{"property" => "tags", "error" => "fewer than minItems 1"} in violations

    {:error, violations} =
      AshA2A.Elicitation.validate(schema, %{"text" => "hi", "tags" => ["ok", 7]})

    assert %{"property" => "tags", "error" => "item 1: expected string, got integer"} in violations

    {:error, violations} =
      AshA2A.Elicitation.validate(schema, %{"text" => "hi", "color" => "blue"})

    assert %{"property" => "color", "error" => "value not in enum"} in violations

    {:error, violations} =
      AshA2A.Elicitation.validate(schema, %{"text" => "hi", "mystery" => 1})

    assert %{"property" => "mystery", "error" => "unknown property"} in violations

    assert {:error, [%{"property" => nil, "error" => "expected an object"}]} =
             AshA2A.Elicitation.validate(schema, "not a map")

    # Union projection (anyOf) and enum-with-titles (oneOf/const).
    any_of = %{
      "type" => "object",
      "properties" => %{"v" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]}},
      "required" => []
    }

    assert AshA2A.Elicitation.validate(any_of, %{"v" => "s"}) == :ok
    assert AshA2A.Elicitation.validate(any_of, %{"v" => 3}) == :ok

    {:error, violations} = AshA2A.Elicitation.validate(any_of, %{"v" => 1.5})
    assert %{"property" => "v", "error" => "matched none of the anyOf branches"} in violations

    one_of = %{
      "type" => "object",
      "properties" => %{
        "c" => %{"oneOf" => [%{"const" => "#f00", "title" => "Red"}, %{"const" => "#0f0", "title" => "Green"}]}
      },
      "required" => []
    }

    assert AshA2A.Elicitation.validate(one_of, %{"c" => "#0f0"}) == :ok

    {:error, violations} = AshA2A.Elicitation.validate(one_of, %{"c" => "#00f"})
    assert %{"property" => "c", "error" => "matched none of the oneOf branches"} in violations

    # A schema that is not a projected object schema fails closed.
    assert {:error, [%{"property" => nil, "error" => "unsupported schema shape"}]} =
             AshA2A.Elicitation.validate(%{"type" => "string"}, "x")
  end

  test "request/3 projects the REAL AshA2A.Schema shape and mints correlation ids" do
    {:ok, elicitation} =
      AshA2A.Elicitation.request(AshA2A.V1ElicitationTest.HomeDomain, :create, task_id: "tsk-x")

    assert "eli-" <> _ = elicitation.id
    assert elicitation.task_id == "tsk-x"
    assert elicitation.mode == :form
    assert elicitation.expires_at == nil

    [part] = AshA2A.Elicitation.to_parts(elicitation)
    assert %AshA2A.Protocol.Part.Data{} = part
    assert part.metadata == %{elicitation_id: elicitation.id, task_id: "tsk-x"}

    wire = part.data["elicitation"]
    assert wire["id"] == elicitation.id
    assert wire["taskId"] == "tsk-x"
    assert wire["requestedSchema"]["properties"]["text"] == %{"type" => "string"}
    assert wire["requestedSchema"]["required"] == ["text"]

    # from_history round-trips the wire map back into a struct.
    history = [AshA2A.Protocol.Message.new_agent(AshA2A.Elicitation.to_parts(elicitation))]
    assert {:ok, rebuilt} = AshA2A.Elicitation.from_history(history)
    assert rebuilt.id == elicitation.id
    assert rebuilt.requested_schema == elicitation.requested_schema
    assert rebuilt.expires_at == nil

    assert :error == AshA2A.Elicitation.from_history([])
    assert :error == AshA2A.Elicitation.from_history([AshA2A.Protocol.Message.new_user("hi")])

    # Expiry semantics.
    assert false == AshA2A.Elicitation.expired?(elicitation)
    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    expired = %{elicitation | expires_at: past}
    assert true == AshA2A.Elicitation.expired?(expired)
  end

  # -- wire helpers -----------------------------------------------------------

  defp post_message(server, message_map) do
    case Req.post(url: server.base_url <> "/message:send", json: %{"message" => message_map}) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> flunk("HTTP POST failed: #{inspect(reason)}")
    end
  end

  defp user_message(data, metadata, task_id \\ nil) do
    base = %{
      "messageId" => "msg-#{System.unique_integer([:positive])}",
      "role" => "ROLE_USER",
      "parts" => [%{"data" => data}],
      "metadata" => metadata
    }

    if task_id, do: Map.put(base, "taskId", task_id), else: base
  end

  defp task_url(server, task_id), do: server.base_url <> "/tasks/" <> task_id

  defp elicitation_part(task) do
    get_in(task, ["status", "message", "parts", Access.at(0), "data", "elicitation"]) ||
      flunk("no elicitation part on parked task: #{inspect(task, limit: 30)}")
  end

  defp error_part(task) do
    get_in(task, ["status", "message", "parts", Access.at(0), "data", "error"]) ||
      flunk("no error part on refused task: #{inspect(task, limit: 30)}")
  end
end
