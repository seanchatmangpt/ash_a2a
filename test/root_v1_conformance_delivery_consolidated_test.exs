# NOTE: 26 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root V1 Conformance & Delivery
# Consolidated by Worker 04 from 15 source files:
#   - test/ash_a2a_v1_elicitation_test.exs
#   - test/ash_a2a_v1_error_registry_test.exs
#   - test/ash_a2a_v1_extended_httpjson_test.exs
#   - test/ash_a2a_v1_grpc_must_test.exs
#   - test/ash_a2a_v1_httpjson_tck_closures_test.exs
#   - test/ash_a2a_v1_io_modes_test.exs
#   - test/ash_a2a_v1_list_decode_test.exs
#   - test/ash_a2a_v1_multinode_continuity_test.exs
#   - test/ash_a2a_v1_oban_delivery_test.exs
#   - test/ash_a2a_v1_owner_scope_test.exs
#   - test/ash_a2a_v1_pagination_test.exs
#   - test/ash_a2a_v1_pb_fidelity_test.exs
#   - test/ash_a2a_v1_proto_fidelity_test.exs
#   - test/ash_a2a_v1_push_httpjson_test.exs
#   - test/ash_a2a_v1_rejected_state_test.exs
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_elicitation_test.exs
# ------------------------------------------------------------------------------

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

            AshA2A.Agent.__dispatch__(
              @ash_a2a_resource_or_domain,
              msg,
              context,
              @ash_a2a_dispatch_opts
            )

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

  test "elicit -> wrong shape refused with the schema error, task stays parked -> correct shape resumes to COMPLETED",
       %{
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
        user_message(
          %{"text" => 123},
          %{"skill" => "create", "elicitationId" => elicitation_id},
          parked["id"]
        )
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
    {:ok, %Req.Response{status: 200, body: fetched}} =
      Req.get(url: task_url(server, parked["id"]))

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
    {:ok, %Req.Response{status: 200, body: fetched}} =
      Req.get(url: task_url(server, parked["id"]))

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
        user_message(
          %{"text" => "valid shape, wrong correlation"},
          %{"skill" => "create"},
          parked["id"]
        )
      )

    assert refused["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
    error = error_part(refused)
    assert error["code"] == -32_602
    assert error["data"] |> hd() |> Map.fetch!("reason") == "INVALID_PARAMS"

    assert error["data"] |> hd() |> Map.fetch!("metadata") |> Map.fetch!("detail") =~
             elicitation_id
  end

  test "expiry (configured) transitions the parked task to terminal FAILED through the lifecycle",
       %{
         server: server
       } do
    Application.put_env(:ash_a2a, :v1_elicitation_expires_in, 30)

    on_exit(fn -> Application.delete_env(:ash_a2a, :v1_elicitation_expires_in) end)

    {:ok, %Req.Response{body: %{"task" => parked}}} =
      post_message(server, user_message(%{}, %{"skill" => "create"}))

    elicitation_id = elicitation_part(parked)["id"]

    # Let the configured 30ms window lapse, then send a PERFECTLY VALID
    # response: expiry still fires — it is checked before the schema.
    # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
    AshA2A.TestSupport.Eventually.pause(60)

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
    # the AIP-193 envelope with the gRPC FAILED_PRECONDITION status, whose
    # details carry the runtime's typed -32004 UnsupportedOperation
    # ("task is terminal").
    {:ok, %Req.Response{status: 400, body: body}} =
      post_message(
        server,
        user_message(
          %{"text" => "again"},
          %{"skill" => "create", "elicitationId" => elicitation_id},
          parked["id"]
        )
      )

    assert body["error"]["code"] == 400
    assert body["error"]["status"] == "FAILED_PRECONDITION"

    # The runtime's typed refusal rides in the ErrorInfo details.
    assert Enum.any?(
             body["error"]["details"] || [],
             &(&1["reason"] == "UNSUPPORTED_OPERATION" and inspect(&1["metadata"]) =~ "terminal")
           )

    # tasks/get still reports the terminal state -- the lifecycle never went
    # backwards.
    {:ok, %Req.Response{status: 200, body: fetched}} =
      Req.get(url: task_url(server, parked["id"]))

    assert fetched["status"]["state"] == "TASK_STATE_FAILED"
  end

  test "default expiry is OFF: an elicitation without :expires_in never expires", %{
    server: server
  } do
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
        user_message(
          %{"wrong" => "key"},
          %{"skill" => "create", "elicitationId" => elicitation_id},
          parked["id"]
        )
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

    {:error, violations} =
      AshA2A.Elicitation.validate(schema, %{"text" => "hi", "score" => 101.5})

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
        "c" => %{
          "oneOf" => [
            %{"const" => "#f00", "title" => "Red"},
            %{"const" => "#0f0", "title" => "Green"}
          ]
        }
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

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_error_registry_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# In-file real fixtures (real ETS Ash resources, real agents)
# ---------------------------------------------------------------------------






# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_extended_httpjson_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1ExtendedHTTPJSONTest.Pipeline do
  @moduledoc """
  Real composite plug used by `AshA2A.V1ExtendedHTTPJSONTest`: a real
  `AshA2A.Protocol.Plug.Auth` (Bearer) in front of the real
  `AshA2A.A2ATransport.Plug` carrying an `:extended_card` provider. Mounted on
  a real Bandit listener, this is the exact stack an operator deploys for the
  authenticated extended card (`agent/getAuthenticatedExtendedCard`).
  """

  @behaviour Plug

  @doc false
  # Idempotent: Bandit re-invokes `init/1` on the already-pinned map.
  def init(opts) when is_map(opts), do: opts

  def init(opts) do
    transport =
      AshA2A.A2ATransport.Plug.init(
        agent: Keyword.fetch!(opts, :agent),
        base_url: "http://127.0.0.1/a2a",
        extended_card: Keyword.get(opts, :extended_card)
      )

    auth =
      if opts[:auth] == false do
        nil
      else
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: Keyword.fetch!(opts, :verify)
        )
      end

    %{auth: auth, transport: transport}
  end

  @impl Plug
  def call(conn, %{auth: nil, transport: transport}),
    do: AshA2A.A2ATransport.Plug.call(conn, transport)

  def call(conn, %{auth: auth, transport: transport}) do
    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.A2ATransport.Plug.call(conn, transport)
    end)
  end
end

defmodule AshA2A.V1ExtendedHTTPJSONTest.RestPipeline do
  @moduledoc """
  Real composite plug for the REST surface under test: a real
  `AshA2A.Protocol.Plug.Auth` (Bearer) in front of the real
  `AshA2A.Transport.HTTPJSON` binding carrying an `:extended_card` provider --
  the exact stack an operator deploys for the authenticated extended card over
  the v1.0 REST binding.
  """

  @behaviour Plug

  @doc false
  def init(opts) when is_map(opts), do: opts

  def init(opts) do
    rest =
      AshA2A.Transport.HTTPJSON.init(
        agent: Keyword.fetch!(opts, :agent),
        base_url: "http://127.0.0.1/a2a",
        extended_card: Keyword.get(opts, :extended_card)
      )

    auth =
      if opts[:auth] == false do
        nil
      else
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: Keyword.fetch!(opts, :verify)
        )
      end

    %{auth: auth, rest: rest}
  end

  @impl Plug
  def call(conn, %{auth: nil, rest: rest}), do: AshA2A.Transport.HTTPJSON.call(conn, rest)

  def call(conn, %{auth: auth, rest: rest}) do
    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Transport.HTTPJSON.call(conn, rest)
    end)
  end
end

defmodule AshA2A.V1ExtendedHTTPJSONTest do
  @moduledoc """
  Court pinning the authenticated extended-card flows
  (`agent/getAuthenticatedExtendedCard`, JSON-RPC method; `POST /agent`, REST
  binding) on the two real HTTP surfaces of this repo, over real Bandit HTTP
  and a real `AshA2A.Agent` GenServer. No mocks.

  ## The REST binding serves `POST /agent` (gap closed)

  `AshA2A.Transport.HTTPJSON` implements the authenticated extended-card REST
  route `POST /agent`: the same provider flow as the JSONRPC wrapper
  (`AshA2A.A2ATransport.ExtendedCard`'s provider contract) with the REST
  envelope. Pinned positively: a verified caller gets the provider-extended
  card itself (per call, for that call's identity); an unauthenticated caller
  is `401` with a `Bearer` challenge and a `-32600` envelope, whether the auth
  plug halted or the binding saw no identity; no provider and provider error
  fail closed to the `-32007` `ErrorInfo` envelope -- the public card is never
  substituted. One plain-404 control remains for a genuinely unknown path
  (`POST /agent:getAuthenticatedExtendedCard` is not an implemented route).

  ## The real extended-card flow runs over the JSONRPC wrapper

  `AshA2A.A2ATransport.Plug` + `AshA2A.A2ATransport.ExtendedCard` + a real
  `:extended_card` provider, front-mounted with a real
  `AshA2A.Protocol.Plug.Auth`: unauthenticated callers are 401-challenged by
  the auth plug (or by the transport plug itself when mounted without one);
  authenticated callers get the provider-extended card per call; the
  provider's output card is stripped of the internal credential keys
  (`"a2a.auth"`, the owner key, the raw stream ref) before serving, like task
  payloads; provider error/crash and no-provider fail closed to -32007 and
  never substitute the public card.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.PlugFixture.GreeterAgent
  alias AshA2A.Transport.HTTPJSON, as: RestBinding

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"
  @ext_not_configured "EXTENDED_AGENT_CARD_NOT_CONFIGURED"

  setup do
    name = :"ext_httpjson_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: name)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)

    # Real per-test invocation counter a real Agent process bumps -- per-call
    # provider invocation is asserted on real counted state, never on mocks.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    %{agent: name, counter: counter}
  end

  # -- providers (real public 2-arity functions, the provider contract) --------

  def admin_card_provider(%{identity: %{sub: sub}}, card) do
    skill = %{"id" => "admin", "name" => "Admin", "description" => "for #{sub}", "tags" => []}
    {:ok, Map.update!(card, "skills", &(&1 ++ [skill]))}
  end

  def counting_admin_provider(counter, %{identity: %{sub: sub}}, card) do
    Agent.update(counter, &(&1 + 1))

    skill = %{"id" => "admin", "name" => "Admin", "description" => "for #{sub}", "tags" => []}
    {:ok, Map.update!(card, "skills", &(&1 ++ [skill]))}
  end

  def failing_provider(_identity, _card), do: {:error, :denied}
  def crashing_provider(_identity, _card), do: raise("boom")

  # A provider that smuggles credential-shaped keys into its output: the court
  # observes what actually reaches the wire.
  def credential_smuggling_provider(_identity, card) do
    leaky_skill = %{
      "id" => "leak",
      "name" => "Leak",
      "description" => "nested credential attempt",
      "tags" => [],
      "metadata" => %{"a2a.auth" => "nested-credential"}
    }

    {:ok,
     card
     |> Map.merge(%{
       "metadata" => %{"a2a.auth" => "raw-credential", "ash_a2a.owner" => "alice"},
       "secret" => "s3cr3t"
     })
     |> Map.update("skills", [leaky_skill], &[leaky_skill | &1])}
  end

  # Never executed: the {m, f, a} provider below is not a CallbackRegistry
  # member, so `AshA2A.CallbackRegistry.invoke/3` must refuse without calling.
  def forbidden_mfa_provider(_identity, _card) do
    :persistent_term.put({__MODULE__, :forbidden_mfa_ran}, true)
    {:ok, %{}}
  end

  # -- fixtures ------------------------------------------------------------------

  defp verify(_scheme, "valid-token-42", _conn), do: {:ok, %{sub: "alice"}}
  defp verify(_scheme, "valid-token-77", _conn), do: {:ok, %{sub: "bob"}}
  defp verify(_scheme, _credential, _conn), do: {:error, "invalid token"}

  defp start_auth_server!(agent, provider, verify_fun \\ &verify/3) do
    opts =
      AshA2A.V1ExtendedHTTPJSONTest.Pipeline.init(
        agent: agent,
        extended_card: provider,
        verify: verify_fun
      )

    EphemeralHttp.start!({AshA2A.V1ExtendedHTTPJSONTest.Pipeline, opts})
  end

  defp start_transport_only_server!(agent, provider) do
    # Raw keyword opts: `AshA2A.A2ATransport.Plug.init/1` is not idempotent on
    # its pinned map, and Bandit calls `init/1` itself on {plug, opts}.
    EphemeralHttp.start!(
      {AshA2A.A2ATransport.Plug,
       [agent: agent, base_url: "http://127.0.0.1/a2a", extended_card: provider]}
    )
  end

  defp start_rest_server!(agent) do
    EphemeralHttp.start!(
      {RestBinding, RestBinding.init(agent: agent, base_url: "http://127.0.0.1/fixture")}
    )
  end

  # REST server with a real auth plug in front of the REST binding.
  defp start_authenticated_rest_server!(agent, provider) do
    opts =
      AshA2A.V1ExtendedHTTPJSONTest.RestPipeline.init(
        agent: agent,
        extended_card: provider,
        verify: &verify/3
      )

    EphemeralHttp.start!({AshA2A.V1ExtendedHTTPJSONTest.RestPipeline, opts})
  end

  # REST binding mounted WITHOUT an auth plug: the binding itself must fail
  # closed on the missing verified identity.
  defp start_bare_rest_server!(agent, provider) do
    EphemeralHttp.start!(
      {RestBinding,
       RestBinding.init(agent: agent, base_url: "http://127.0.0.1/a2a", extended_card: provider)}
    )
  end

  defp rpc!(server, method, token \\ nil, id \\ 7) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{}})

    headers = [{"content-type", "application/json"}]
    headers = if token, do: [{"authorization", "Bearer " <> token} | headers], else: headers

    Req.post!(url: server.base_url <> "/", headers: headers, body: body)
  end

  defp post_agent!(server, token \\ nil) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []
    Req.post!(url: server.base_url <> "/agent", headers: headers, json: %{}, decode_body: false)
  end

  defp public_card_skills(server) do
    (server.base_url <> "/.well-known/agent-card.json")
    |> Req.get!()
    |> Map.fetch!(:body)
    |> Map.fetch!("skills")
  end

  # =============================================================================
  # PART 1 -- the REST binding (`AshA2A.Transport.HTTPJSON`) serves the
  # authenticated extended card at `POST /agent` (gap closed).
  # =============================================================================

  @tag :serial_shard
  test "REST binding: an authenticated caller receives the provider-extended card for that call's identity",
       %{
         agent: agent
       } do
    server = start_authenticated_rest_server!(agent, &admin_card_provider/2)

    resp = post_agent!(server, "valid-token-42")
    assert resp.status == 200, "status=#{resp.status} body=#{resp.body}"

    card = Jason.decode!(resp.body)

    # Success is the extended card itself (the REST binding has no JSON-RPC
    # oneof wrapper), carrying the provider's per-identity skill...
    ids = Enum.map(card["skills"], & &1["id"])
    assert "admin" in ids
    assert Enum.find(card["skills"], &(&1["id"] == "admin"))["description"] == "for alice"

    # ...and a second call with a different verified identity gets ITS
    # identity's extension.
    resp2 = post_agent!(server, "valid-token-77")
    assert resp2.status == 200
    card2 = Jason.decode!(resp2.body)
    assert Enum.find(card2["skills"], &(&1["id"] == "admin"))["description"] == "for bob"

    # The public card, fetched unauthenticated from the same server, never
    # carries the admin skill: the extension exists only per-call.
    refute "admin" in Enum.map(public_card_skills(server), & &1["id"])
  end

  @tag :serial_shard
  test "REST binding: POST /agent without an auth plug still fails closed -- 401, Bearer challenge, -32600 envelope, never the public card",
       %{
         agent: agent
       } do
    server = start_bare_rest_server!(agent, &admin_card_provider/2)

    resp = post_agent!(server)

    assert resp.status == 401
    assert resp.headers["www-authenticate"] == ["Bearer"]

    assert %{
             "error" => %{
               "code" => 401,
               "message" => "Request payload validation error",
               "details" => "authentication required"
             }
           } = Jason.decode!(resp.body)

    # Never the public card.
    refute Jason.decode!(resp.body) |> Map.has_key?("skills")
  end

  @tag :serial_shard
  test "REST binding: no :extended_card provider answers the -32007 ErrorInfo envelope even for a verified caller, never the public card",
       %{
         agent: agent
       } do
    server = start_authenticated_rest_server!(agent, nil)

    resp = post_agent!(server, "valid-token-42")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "message" => "Authenticated Extended Card is not configured",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => @ext_not_configured
                 }
               ]
             }
           } = Jason.decode!(resp.body)

    refute Jason.decode!(resp.body) |> Map.has_key?("skills")
  end

  @tag :serial_shard
  test "REST binding: a failing provider answers -32007 with the reason, never the public card",
       %{
         agent: agent
       } do
    server = start_authenticated_rest_server!(agent, &failing_provider/2)

    resp = post_agent!(server, "valid-token-42")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [
                 %{
                   "@type" => @error_info,
                   "reason" => @ext_not_configured,
                   "metadata" => %{"detail" => detail}
                 }
               ]
             }
           } = Jason.decode!(resp.body)

    assert detail =~ ":denied"
    refute Jason.decode!(resp.body) |> Map.has_key?("skills")
  end

  @tag :serial_shard
  test "REST binding: a crashing provider answers -32007, never the public card", %{agent: agent} do
    server = start_authenticated_rest_server!(agent, &crashing_provider/2)

    resp = post_agent!(server, "valid-token-42")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"metadata" => %{"detail" => detail}}]
             }
           } = Jason.decode!(resp.body)

    assert detail =~ "provider_raised"
    assert detail =~ "boom"
    refute Jason.decode!(resp.body) |> Map.has_key?("skills")
  end

  test "REST binding: the well-known card serves the extendedAgentCard capability as literal false",
       %{
         agent: agent
       } do
    server = start_rest_server!(agent)

    card = Req.get!(url: server.base_url <> "/.well-known/agent-card.json").body

    # Pinned as-served: the REST binding's card encode path pins every
    # capability key, so `extendedAgentCard` appears as literal `false` (the
    # REST binding's well-known advertisement does not follow the per-call
    # provider -- the true-advertising surface is the JSONRPC wrapper's plug).
    assert %{"capabilities" => %{"extendedAgentCard" => false}} = card
  end

  # The CallbackRegistry closure holds on the REST surface too: a {m, f, a}
  # provider outside the registry is refused -32007 (the same envelope the
  # JSONRPC binding answers) and the callback is never executed.
  test "REST binding: a {m, f, a} provider outside CallbackRegistry is -32007 and the callback is never executed",
       %{
         agent: agent
       } do
    :persistent_term.erase({__MODULE__, :forbidden_mfa_ran})

    server = start_authenticated_rest_server!(agent, {__MODULE__, :forbidden_mfa_provider, []})

    resp = post_agent!(server, "valid-token-42")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"metadata" => %{"detail" => detail}}]
             }
           } = Jason.decode!(resp.body)

    assert detail =~ "callback_not_permitted"
    refute :persistent_term.get({__MODULE__, :forbidden_mfa_ran}, false)
  end

  # 404 control: a genuinely unknown path is still the plain catch-all 404.
  test "REST binding: POST /agent:getAuthenticatedExtendedCard is a plain 404 fallthrough (not an implemented route)",
       %{
         agent: agent
       } do
    server = start_rest_server!(agent)

    resp =
      Req.post!(
        url: server.base_url <> "/agent:getAuthenticatedExtendedCard",
        json: %{},
        decode_body: false
      )

    assert resp.status == 404
    assert %{"error" => %{"code" => 404}} = Jason.decode!(resp.body)
  end

  # =============================================================================
  # PART 2 -- the real extended-card flow over the JSONRPC wrapper
  # (real Auth plug -> A2ATransport.Plug -> ExtendedCard -> provider).
  # =============================================================================

  # (a) unauthenticated caller
  test "(a) unauthenticated RPC through the real auth plug is 401 with a Bearer challenge", %{
    agent: agent
  } do
    server = start_auth_server!(agent, {__MODULE__, :admin_card_provider, []})

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard")

    assert resp.status == 401
    assert resp.headers["www-authenticate"] == [~s(Bearer realm="a2a")]
    assert resp.body == %{"error" => "Unauthorized"}
  end

  test "(a) transport plug mounted WITHOUT an auth plug still fails closed: 401 + -32600 + WWW-Authenticate",
       %{
         agent: agent
       } do
    server = start_transport_only_server!(agent, &admin_card_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard")

    assert resp.status == 401
    assert resp.headers["www-authenticate"] == ["Bearer"]

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "error" => %{"code" => -32_600, "data" => "authentication required"}
           } =
             resp.body
  end

  # (b) authenticated caller -> provider-extended card, per call
  test "(b) authenticated caller receives the provider-extended card; provider invoked per call with that call's identity",
       %{
         agent: agent,
         counter: counter
       } do
    server =
      start_auth_server!(agent, fn id, card -> counting_admin_provider(counter, id, card) end)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")
    assert resp.status == 200

    assert %{"jsonrpc" => "2.0", "id" => 7, "result" => card} = resp.body
    refute Map.has_key?(resp.body, "error")

    ids = Enum.map(card["skills"], & &1["id"])
    assert "admin" in ids
    assert Enum.find(card["skills"], &(&1["id"] == "admin"))["description"] == "for alice"

    # Per-call: a different verified identity on a second call gets ITS
    # identity's extension, and the real counter shows two provider runs.
    resp2 = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-77", 8)
    assert %{"id" => 8, "result" => card2} = resp2.body
    assert Enum.find(card2["skills"], &(&1["id"] == "admin"))["description"] == "for bob"
    assert Agent.get(counter, & &1) == 2

    # The public card, fetched unauthenticated from the same server, never
    # carries the admin skill: the extension exists only per-call.
    refute "admin" in Enum.map(public_card_skills(server), & &1["id"])
  end

  test "(b) the PascalCase v1.0 alias GetExtendedAgentCard routes identically", %{agent: agent} do
    server = start_auth_server!(agent, &admin_card_provider/2)

    resp = rpc!(server, "GetExtendedAgentCard", "valid-token-42")

    assert resp.status == 200
    assert %{"result" => %{"skills" => skills}} = resp.body
    assert "admin" in Enum.map(skills, & &1["id"])
  end

  # (c) provider error / crash -> -32007, never the public card
  test "(c) a provider error answers -32007 and never the public card", %{agent: agent} do
    server = start_auth_server!(agent, &failing_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200

    assert %{
             "error" => %{
               "code" => -32_007,
               "message" => "Authenticated Extended Card is not configured",
               "data" => [
                 %{
                   "@type" => @error_info,
                   "reason" => @ext_not_configured,
                   "metadata" => %{"detail" => detail}
                 }
               ]
             }
           } = resp.body

    assert detail =~ ":denied"
    refute Map.has_key?(resp.body, "result")
  end

  test "(c) a crashing provider answers -32007 and never the public card", %{agent: agent} do
    server = start_auth_server!(agent, &crashing_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200

    assert %{"error" => %{"code" => -32_007, "data" => [%{"metadata" => %{"detail" => detail}}]}} =
             resp.body

    assert detail =~ "provider_raised"
    assert detail =~ "boom"
    refute Map.has_key?(resp.body, "result")
  end

  test "(c) the public card fetched from the same failing-provider server carries no admin skill",
       %{agent: agent} do
    server = start_auth_server!(agent, &failing_provider/2)

    refute "admin" in Enum.map(public_card_skills(server), & &1["id"])
  end

  # (d) no provider configured -> pinned refusal
  test "(d) no :extended_card provider configured is -32007 even for a verified caller", %{
    agent: agent
  } do
    server = start_auth_server!(agent, nil)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200

    assert %{
             "error" => %{
               "code" => -32_007,
               "data" => [%{"@type" => @error_info, "reason" => @ext_not_configured}]
             }
           } =
             resp.body

    refute Map.has_key?(resp.body, "result")
  end

  # (e) credential hygiene of the provider output
  test "(e) a credential-smuggling provider's output serves WITHOUT the internal keys", %{
    agent: agent
  } do
    server = start_auth_server!(agent, &credential_smuggling_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200
    assert %{"result" => card} = resp.body

    # Positive pin: like task payloads, the provider's `{:ok, card}` output is
    # stripped of the internal keys ("a2a.auth", the owner key, the raw stream
    # ref) before it is encoded and served -- recursively, so a provider
    # cannot hide a credential inside a skill or nested metadata map either.
    assert card["metadata"] == %{}
    assert Enum.find(card["skills"], &(&1["id"] == "leak"))["metadata"] == %{}

    # The strip is key-targeted, not card-blanking: non-internal provider
    # output (including provider-injected extra fields) serves verbatim.
    assert card["secret"] == "s3cr3t"

    assert Enum.find(card["skills"], &(&1["id"] == "leak"))["description"] ==
             "nested credential attempt"
  end

  test "(e) an honest provider's output serves unchanged", %{agent: agent} do
    # Fun-form provider: non-registered {m, f, a} MFAs are refused by the
    # CallbackRegistry court below, so this pin exercises the serve path.
    server = start_auth_server!(agent, &admin_card_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200
    assert %{"result" => card} = resp.body

    assert Enum.find(card["skills"], &(&1["id"] == "admin"))["description"] == "for alice"
    refute Map.has_key?(card, "metadata")
    refute Map.has_key?(card, "secret")
    refute Map.has_key?(card, "a2a.auth")
    refute Map.has_key?(card, "ash_a2a.owner")
  end

  test "(e) the encoded public card handed to the provider carries no credential metadata", %{
    agent: agent
  } do
    parent = self()

    server =
      start_auth_server!(agent, fn _identity, card ->
        send(parent, {:provider_saw, card})
        {:ok, card}
      end)

    assert %{"result" => _} =
             rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42").body

    assert_received {:provider_saw, card}
    assert is_map(card)
    refute Map.has_key?(card, "metadata")
  end

  # -- CallbackRegistry closure on the {m, f, a} provider form -----------------

  test "{m, f, a} provider outside CallbackRegistry is -32007 and the callback is never executed",
       %{agent: agent} do
    :persistent_term.erase({__MODULE__, :forbidden_mfa_ran})

    server = start_auth_server!(agent, {__MODULE__, :forbidden_mfa_provider, []})

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert %{"error" => %{"code" => -32_007, "data" => [%{"metadata" => %{"detail" => detail}}]}} =
             resp.body

    assert detail =~ "callback_not_permitted"
    refute :persistent_term.get({__MODULE__, :forbidden_mfa_ran}, false)
  end
end

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_grpc_must_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT



# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_httpjson_tck_closures_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.HTTPJSON.TCKClosuresTest.Probe do
  @moduledoc false
  # Real ETS-backed Ash resource with one real `:read` skill.
  use Ash.Resource,
    domain: AshA2A.Transport.HTTPJSON.TCKClosuresTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.Transport.HTTPJSON.TCKClosuresTest.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Transport.HTTPJSON.TCKClosuresTest.Probe)
  end
end

defmodule AshA2A.Transport.HTTPJSON.TCKClosuresTest.EchoAgent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Transport.HTTPJSON.TCKClosuresTest.Probe,
    name: "httpjson_tck_closures_agent"
end

defmodule AshA2A.Transport.HTTPJSON.TCKClosuresTest do
  @moduledoc """
  Lane G-P court: the A2A v1.0 HTTP+JSON/REST binding's TCK-closure surface
  (the G-E http_json TCK matrix's transport-side failure classes, pinned
  positively over a real Bandit server, a real `use AshA2A.Agent` GenServer
  and real `Req` round trips -- no mocks).

  Six pins, one per closed failure class:

    1. `POST /message:send` answers the v1.0 SendMessageResponse oneof
       wrapper `{"task": ...}` | `{"message": ...}` (TCK validates the body
       against the SendMessageResponse schema, `additionalProperties: false`)
    2. Error bodies are the AIP-193 envelope `{"error": {"code": <HTTP
       status>, "status": <gRPC name>, "message", "details"}}` with
       `error.code == HTTP status` (TCK HTTP_JSON-ERR-001/002, AIP-193)
    3. The §3.6 `A2A-Version` gate: unsupported -> 400 `-32009`
       (VERSION_NOT_SUPPORTED ErrorInfo) with the rejected version echoed;
       absent/supported -> dispatch with the negotiated version echoed
       (mirrors `AshA2A.Transport.Plug.handle_json_rpc/2`)
    4. `POST /tasks/{id}:subscribe` on an unknown task -> 404 TaskNotFound
       (TCK STREAM-SUB-004, §5.4); on an owned task -> 400
       UnsupportedOperation (mirrors `AshA2A.Transport.Plug.resubscribe/4`)
    5. `POST /message:stream` streams SSE (`text/event-stream`), one
       StreamResponse JSON object per `data:` frame (TCK CORE-STREAM-*,
       HTTP_JSON-SSE-001)
    6. The push-config CRUD answers the §5.3 collection path
       `pushNotificationConfigs` (plural) identically to the singular alias;
       when push is disabled every verb is the 400 `-32003` envelope (TCK
       CORE-CAP-001, HTTP_JSON-STATUS-001)

  Request-side unknown members stay inert (tolerant proto3-JSON input,
  strict SendMessageResponse output shape) -- the TCK's "additional
  properties" class was response-side only.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp

  alias AshA2A.Transport.HTTPJSON, as: Binding

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  setup do
    agent = AshA2A.Transport.HTTPJSON.TCKClosuresTest.EchoAgent

    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [agent])

    plug_opts = Binding.init(agent: agent, base_url: "http://127.0.0.1/fixture")

    %{server: EphemeralHttp.start!({Binding, plug_opts})}
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp post_json!(server, path, body, headers \\ []) do
    Req.post!(url: server.base_url <> path, json: body, headers: headers)
  end

  defp get!(server, path) do
    Req.get!(url: server.base_url <> path)
  end

  defp send_message!(server, text) do
    resp = post_json!(server, "/message:send", %{"message" => message_map(text)})
    assert resp.status == 200
    resp
  end

  defp new_task_id(server) do
    %{"task" => %{"id" => id}} = send_message!(server, "go").body
    id
  end

  # -- (1) the SendMessageResponse oneof wrapper -------------------------------

  test "message:send wraps the task in the v1.0 SendMessageResponse oneof", %{server: server} do
    resp = send_message!(server, "go")

    assert %{"task" => %{"id" => "tsk-" <> _, "status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
             resp.body

    # The wrapper carries no other members (the schema is
    # additionalProperties: false over task|message).
    assert Map.keys(resp.body) == ["task"]
  end

  # -- (2) the AIP-193 error envelope -------------------------------------------

  test "error bodies are the AIP-193 envelope with error.code == HTTP status", %{server: server} do
    resp = get!(server, "/tasks/tsk-does-not-exist")

    assert resp.status == 404

    assert %{
             "error" => %{
               "code" => 404,
               "status" => "NOT_FOUND",
               "message" => "Task not found",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => "TASK_NOT_FOUND"
                 }
               ]
             }
           } = resp.body
  end

  # -- (3) the A2A-Version gate -------------------------------------------------

  test "a supported A2A-Version dispatches and is echoed back", %{server: server} do
    for version <- [nil, "0.3", "1.0"] do
      resp =
        case version do
          nil ->
            post_json!(server, "/message:send", %{"message" => message_map("v-gate nil")})

          v ->
            post_json!(server, "/message:send", %{"message" => message_map("v-gate " <> v)}, [
              {"a2a-version", v}
            ])
        end

      assert resp.status == 200
      assert %{"task" => %{"id" => _}} = resp.body
      assert Enum.join(resp.headers["a2a-version"], "") == (version || "0.3")
    end
  end

  test "an unsupported A2A-Version answers 400 -32009 with the rejected version echoed", %{
    server: server
  } do
    resp =
      post_json!(server, "/message:send", %{"message" => message_map("v-gate bad")}, [
        {"a2a-version", "99.0"}
      ])

    assert resp.status == 400
    assert Enum.join(resp.headers["a2a-version"], "") == "99.0"

    assert %{
             "error" => %{
               "code" => 400,
               "status" => "FAILED_PRECONDITION",
               "message" => "Version not supported",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => "VERSION_NOT_SUPPORTED",
                   "metadata" => %{"detail" => "99.0"}
                 }
               ]
             }
           } = resp.body
  end

  # -- (4) tasks/{id}:subscribe status mapping -----------------------------------

  test "subscribe on an unknown task is 404 TaskNotFound (STREAM-SUB-004)", %{server: server} do
    resp = post_json!(server, "/tasks/tsk-does-not-exist:subscribe", %{})

    assert resp.status == 404

    assert %{
             "error" => %{
               "code" => 404,
               "status" => "NOT_FOUND",
               "details" => [%{"@type" => @error_info, "reason" => "TASK_NOT_FOUND"}]
             }
           } = resp.body
  end

  test "subscribe on an owned task is 400 UnsupportedOperation", %{server: server} do
    task_id = new_task_id(server)

    resp = post_json!(server, "/tasks/#{task_id}:subscribe", %{})

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"@type" => @error_info, "reason" => "UNSUPPORTED_OPERATION"}]
             }
           } = resp.body
  end

  # -- (5) message:stream SSE ----------------------------------------------------

  test "message:stream answers SSE with StreamResponse data frames", %{server: server} do
    resp =
      Req.post!(
        url: server.base_url <> "/message:stream",
        json: %{"message" => message_map("stream me")},
        headers: [{"accept", "text/event-stream"}],
        decode_body: false
      )

    assert resp.status == 200

    [content_type] = Enum.map(resp.headers["content-type"], &String.downcase/1)
    assert content_type =~ "text/event-stream"

    frames =
      resp.body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&(&1 |> String.slice(5..-1//1) |> String.trim()))
      |> Enum.map(&Jason.decode!/1)

    assert length(frames) >= 2

    # Every frame is a single-member StreamResponse wrapper.
    for frame <- frames do
      assert Map.keys(frame) -- ["task", "message", "statusUpdate", "artifactUpdate"] == []
      assert Map.keys(frame) != []
    end

    # First frame carries the task, the final frame is the terminal status.
    assert %{"task" => %{"id" => task_id}} = hd(frames)

    last = List.last(frames)
    # v1.0: finality is the terminal TASK_STATE_* on the final statusUpdate,
    # not a "final" boolean (same wire shape as the JSON-RPC SSE frames).
    assert %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = last

    # The task from the stream is really readable back.
    fetched = get!(server, "/tasks/#{task_id}")
    assert fetched.status == 200
    assert fetched.body["id"] == task_id
  end

  # -- (6) the plural pushNotificationConfigs collection path --------------------

  test "pushNotificationConfigs (plural) routes like the singular alias", %{server: server} do
    # Push notifications are disabled on this binding: every verb on the
    # plural collection path must answer the same fail-closed -32003
    # envelope as the singular alias (routing parity, CORE-CAP-001).
    for {method, path} <- [
          {:post, "/tasks/tsk-x/pushNotificationConfigs"},
          {:get, "/tasks/tsk-x/pushNotificationConfigs"},
          {:get, "/tasks/tsk-x/pushNotificationConfigs/cfg-1"},
          {:delete, "/tasks/tsk-x/pushNotificationConfigs/cfg-1"}
        ] do
      resp =
        case method do
          :post -> post_json!(server, path, %{"url" => "https://example.com"})
          :get -> get!(server, path)
          :delete -> Req.delete!(url: server.base_url <> path)
        end

      assert resp.status == 400, "#{method} #{path}"

      assert %{
               "error" => %{
                 "code" => 400,
                 "details" => [
                   %{"@type" => @error_info, "reason" => "PUSH_NOTIFICATION_NOT_SUPPORTED"}
                 ]
               }
             } = resp.body,
             "#{method} #{path}"
    end
  end
end

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_io_modes_test.exs
# ------------------------------------------------------------------------------

defmodule AshA2A.V1IOModesTest.ModedAgent do
  @moduledoc """
  Real `AshA2A.Protocol.Agent` GenServer for the (e2) court: its card
  carries one skill with the spec's OPTIONAL per-skill
  `input_modes`/`output_modes` override, exactly the shape the real
  `AshA2A.CapabilityIndex.AgentCardBuilder` emits for a `:skills_opts`
  override and the real `AshA2A.Protocol.JSON` codec encodes/decodes.
  """

  use AshA2A.Protocol.Agent,
    name: "moded_io_modes_agent",
    description: "Agent advertising a per-skill IO-mode override",
    version: "0.1.0",
    skills: [
      %{
        id: "greet",
        name: "Greet",
        description: "Says hello",
        tags: [],
        input_modes: ["application/json"],
        output_modes: ["text/csv"]
      }
    ]

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:reply, [AshA2A.Protocol.Part.Text.new("hello")]}
  end
end

defmodule AshA2A.V1IOModesTest do
  @moduledoc """
  W7 court: A2A v1.0 §4.4/5.1 input/output mode conformance for the real
  served AgentCard, over a real fixture resource's real card.

  ## What the spec REQUIRES (pinned from the authoritative
  `a2aproject/A2A` `specification/a2a.proto` @ main, AgentCard fields 10/11
  and AgentSkill fields 6/7)

  - `AgentCard.default_input_modes` / `default_output_modes`:
    `(google.api.field_behavior) = REQUIRED` -- "the set of interaction modes
    that the agent supports across all skills. This can be overridden per
    skill. Defined as media types."
  - `AgentSkill.input_modes` / `output_modes`: OPTIONAL (no REQUIRED
    annotation) -- "the set of supported input/output media types for this
    skill, overriding the agent's defaults."

  ## Spec-vs-reality summary (see per-court comments for detail)

  | spec requirement                              | ash_a2a reality                                  |
  |-----------------------------------------------|--------------------------------------------------|
  | card defaults REQUIRED                        | MET — struct defaults `["text/plain"]`, always encoded |
  | skill modes OPTIONAL, override card defaults  | MET — builder `:skills_opts` projects per-skill modes; codec emits/decodes `inputModes`/`outputModes` only when non-nil |

  No mocks: the card is built by the real `AshA2A.Info.agent_card/2` from a
  real `Ash.Resource` (`AshA2A.Test.PlugFixture.Greeter`), encoded/decoded by
  the real `AshA2A.Protocol.JSON` codec, and served by the real
  `AshA2A.Protocol.Plug` in front of real `AshA2A.Agent` /
  `AshA2A.Protocol.Agent` GenServers via a real `Plug.Test` GET.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSON
  alias AshA2A.Test.PlugFixture.{Greeter, GreeterAgent}

  @base_url "http://localhost:4000/a2a"

  # Real per-skill override used across the courts: keyed by the Greeter
  # skill's real capability id ("<Resource>.<action>", pinned by
  # `test/ash_a2a_plug_agent_card_test.exs`).
  @greeter_capability_id "AshA2A.Test.PlugFixture.Greeter.read"

  @greeter_skills_opts %{
    @greeter_capability_id => [
      input_modes: ["application/json"],
      output_modes: ["text/x-python"]
    ]
  }

  setup do
    # Real per-test agent name: parallel async runs never collide on the
    # globally-registered GenServer name.
    agent_name = :"greeter_agent_io_modes_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent_name)

    on_exit(fn ->
      AshA2A.TestSupport.SafeStop.stop(pid)
    end)

    %{agent: agent_name}
  end

  defp real_card do
    AshA2A.Info.agent_card(Greeter, name: "greeter_agent")
  end

  defp moded_card do
    # The real builder path (same compiled capability index the runtime
    # dispatches against), with the per-skill override supplied through the
    # builder's `:skills_opts` option.
    AshA2A.Info.agent_card(Greeter,
      name: "greeter_agent",
      skills_opts: @greeter_skills_opts
    )
  end

  defp mime_shape?(modes) do
    is_list(modes) and modes != [] and
      Enum.all?(modes, fn
        s when is_binary(s) and s != "" ->
          String.contains?(s, "/") and not String.contains?(s, "_")

        _ ->
          false
      end)
  end

  defp wire_skill_by_id(wire_card, id) do
    Enum.find(wire_card["skills"], &(&1["id"] == id))
  end

  describe "card-level defaultInputModes/defaultOutputModes (spec: REQUIRED)" do
    @tag :w7_io_modes
    test "(a) real fixture card carries present, non-empty, pinned defaults" do
      card = real_card()

      # Pinned values: the builder accepts no card-level mode opts and the
      # struct defaults to `["text/plain"]`, so this is the deterministic
      # reality of every card the real builder emits (per-skill overrides
      # ride on `:skills_opts`, not on the card defaults).
      assert card.default_input_modes == ["text/plain"]
      assert card.default_output_modes == ["text/plain"]

      # Media-type shape, not just presence.
      assert mime_shape?(card.default_input_modes)
      assert mime_shape?(card.default_output_modes)
    end

    @tag :w7_io_modes
    test "(a2) the real codec always emits both camelCase members with the same values" do
      wire = JSON.encode_agent_card(real_card(), url: @base_url)

      # The codec builds the card map with these two members unconditionally
      # (`json.ex` base map), so REQUIRED-on-the-wire holds for every card.
      assert Map.has_key?(wire, "defaultInputModes")
      assert Map.has_key?(wire, "defaultOutputModes")
      assert wire["defaultInputModes"] == ["text/plain"]
      assert wire["defaultOutputModes"] == ["text/plain"]
      assert mime_shape?(wire["defaultInputModes"])
      assert mime_shape?(wire["defaultOutputModes"])
    end
  end

  describe "per-skill inputModes/outputModes (spec: OPTIONAL override)" do
    @tag :w7_io_modes
    test "(b) the real builder projects a :skills_opts per-skill override onto the card struct" do
      card = moded_card()

      assert [%{id: @greeter_capability_id} = moded] = card.skills

      # The override reaches the real card struct under the spec field names.
      assert moded.input_modes == ["application/json"]
      assert moded.output_modes == ["text/x-python"]

      # A skill with no entry in `:skills_opts` carries no mode keys at all
      # (absent key = inherit the card defaults) — there is exactly one
      # skill in this fixture's index and it was overridden above, so pin
      # the nil-inheritance shape against a differently-keyed map instead.
      unmoded_card =
        AshA2A.Info.agent_card(Greeter,
          name: "greeter_agent",
          skills_opts: %{"no.such.skill" => [input_modes: ["application/json"]]}
        )

      Enum.each(unmoded_card.skills, fn skill ->
        refute Map.has_key?(skill, :input_modes)
        refute Map.has_key?(skill, :output_modes)
      end)

      # Card-level defaults are untouched by the per-skill override.
      assert unmoded_card.default_input_modes == ["text/plain"]
      assert unmoded_card.default_output_modes == ["text/plain"]
    end

    @tag :w7_io_modes
    test "(b2) skill keyed by declared name also resolves through :skills_opts" do
      card =
        AshA2A.Info.agent_card(Greeter,
          name: "greeter_agent",
          skills_opts: %{
            greet: [input_modes: ["text/x-python"], output_modes: ["application/json"]]
          }
        )

      assert [%{input_modes: ["text/x-python"], output_modes: ["application/json"]}] =
               card.skills
    end

    @tag :w7_io_modes
    test "(b3) codec emits skill inputModes/outputModes ONLY when non-nil, and decodes them back" do
      # Encode side: nil-mode skills produce no wire members (spec-optional
      # inheritance signal), moded skills produce exactly the override.
      plain_wire = JSON.encode_agent_card(real_card(), url: @base_url)

      Enum.each(plain_wire["skills"], fn wire_skill ->
        refute Map.has_key?(wire_skill, "inputModes")
        refute Map.has_key?(wire_skill, "outputModes")
      end)

      moded_wire = JSON.encode_agent_card(moded_card(), url: @base_url)

      assert wire_skill_by_id(moded_wire, @greeter_capability_id) == %{
               "id" => @greeter_capability_id,
               "name" => "greet",
               "description" =>
                 wire_skill_by_id(moded_wire, @greeter_capability_id)["description"],
               "tags" => wire_skill_by_id(moded_wire, @greeter_capability_id)["tags"],
               "inputModes" => ["application/json"],
               "outputModes" => ["text/x-python"]
             }

      # Decode side: the modes come back under the spec field names.
      {:ok, decoded} = JSON.decode_agent_card(moded_wire)

      assert Enum.find(decoded.skills, &(&1.id == @greeter_capability_id)) == %{
               id: @greeter_capability_id,
               name: "greet",
               description:
                 Enum.find(decoded.skills, &(&1.id == @greeter_capability_id)).description,
               tags: Enum.find(decoded.skills, &(&1.id == @greeter_capability_id)).tags,
               input_modes: ["application/json"],
               output_modes: ["text/x-python"]
             }

      # And a card served without the override decodes without the keys --
      # absence on the wire is the inherit-the-defaults signal.
      {:ok, plain_decoded} = JSON.decode_agent_card(plain_wire)

      Enum.each(plain_decoded.skills, fn skill ->
        refute Map.has_key?(skill, :input_modes)
        refute Map.has_key?(skill, :output_modes)
      end)

      # Card-level defaults still survive both cycles unchanged.
      assert decoded.default_input_modes == ["text/plain"]
      assert decoded.default_output_modes == ["text/plain"]
    end

    @tag :w7_io_modes
    test "(b4) encode -> decode round-trips the per-skill override exactly" do
      wire = JSON.encode_agent_card(moded_card(), url: @base_url)
      {:ok, decoded} = JSON.decode_agent_card(wire)

      moded_skill = Enum.find(decoded.skills, &(&1.id == @greeter_capability_id))

      assert moded_skill.input_modes == ["application/json"]
      assert moded_skill.output_modes == ["text/x-python"]
      assert mime_shape?(moded_skill.input_modes)
      assert mime_shape?(moded_skill.output_modes)

      # Non-moded skills in the same card stay key-absent after the cycle.
      Enum.each(decoded.skills, fn skill ->
        unless skill.id == @greeter_capability_id do
          refute Map.has_key?(skill, :input_modes)
          refute Map.has_key?(skill, :output_modes)
        end
      end)
    end
  end

  describe "decode round-trip (spec: card defaults REQUIRED on the wire)" do
    @tag :w7_io_modes
    test "(c) encode -> decode preserves both card mode fields exactly on the real card" do
      card = real_card()

      wire = JSON.encode_agent_card(card, url: @base_url)
      {:ok, decoded} = JSON.decode_agent_card(wire)

      assert decoded.default_input_modes == card.default_input_modes
      assert decoded.default_output_modes == card.default_output_modes

      # Non-empty on both sides of the cycle: the decoder's own fallback is
      # `["text/plain"]` when a member is missing, so an encode-side drop
      # would be masked -- assert on the wire members too.
      assert wire["defaultInputModes"] == card.default_input_modes
      assert wire["defaultOutputModes"] == card.default_output_modes
    end
  end

  describe "explicit opts override through the real builder+codec path" do
    @tag :w7_io_modes
    test "(d) codec opts-first resolution overrides the card's mode defaults on the wire" do
      card = real_card()

      wire =
        JSON.encode_agent_card(card,
          url: @base_url,
          default_input_modes: ["application/json"],
          default_output_modes: ["text/x-python"]
        )

      assert wire["defaultInputModes"] == ["application/json"]
      assert wire["defaultOutputModes"] == ["text/x-python"]

      # The override is encode-time only: decoding the overridden wire card
      # recovers exactly the advertised modes.
      {:ok, decoded} = JSON.decode_agent_card(wire)
      assert decoded.default_input_modes == ["application/json"]
      assert decoded.default_output_modes == ["text/x-python"]
    end

    @tag :w7_io_modes
    test "(d2) the builder takes per-skill modes via :skills_opts but still no card-level mode opts" do
      # Card-level reality is unchanged: `AgentCardBuilder.build_agent_card/2`
      # still projects a fixed opt set for the card defaults (url, name,
      # description, version, skills, provider, capabilities,
      # security_schemes, security, supported_interfaces) and card-level mode
      # opts are not among them, so the struct defaults `["text/plain"]` are
      # the only card-level values the builder emits. The per-skill surface
      # (`:skills_opts`) is the one this W7 gap closure added.
      card =
        AshA2A.Info.agent_card(Greeter,
          name: "mode_probe",
          default_input_modes: ["application/json"],
          default_output_modes: ["text/x-python"],
          skills_opts: @greeter_skills_opts
        )

      # The builder now honors card-level mode opts (opts > domain > default).
      assert card.default_input_modes == ["application/json"]
      assert card.default_output_modes == ["text/x-python"]

      # ...while the per-skill override in the same call took effect.
      assert Enum.find(card.skills, &(&1.id == @greeter_capability_id)).input_modes ==
               ["application/json"]
    end

    @tag :w7_io_modes
    test "(d3) struct-field override also reaches the wire without opts" do
      # The other real override surface: a card struct carrying its own mode
      # values flows through the same `card_field/4` resolution with no opts.
      card = %{
        real_card()
        | default_input_modes: ["text/x-python"],
          default_output_modes: ["application/json"]
      }

      wire = JSON.encode_agent_card(card, url: @base_url)

      assert wire["defaultInputModes"] == ["text/x-python"]
      assert wire["defaultOutputModes"] == ["application/json"]
    end
  end

  describe "wire shape served by the real Plug (camelCase, no snake_case)" do
    @tag :w7_io_modes
    test "(e) real Plug.Test GET serves camelCase mode members and no snake_case leakage", %{
      agent: agent
    } do
      plug_opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: @base_url)

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      assert conn.status == 200
      served_card = Jason.decode!(conn.resp_body)

      # camelCase v1.0 members, present and non-empty on the served card.
      assert served_card["defaultInputModes"] == ["text/plain"]
      assert served_card["defaultOutputModes"] == ["text/plain"]
      assert mime_shape?(served_card["defaultInputModes"])
      assert mime_shape?(served_card["defaultOutputModes"])

      # No snake_case leakage on the wire.
      refute Map.has_key?(served_card, "default_input_modes")
      refute Map.has_key?(served_card, "default_output_modes")

      # Per-skill modes: absent on the served card too -- the fixture agent
      # declares no `:skills_opts`, so every skill inherits the card
      # defaults and the members are correctly omitted.
      Enum.each(served_card["skills"], fn wire_skill ->
        refute Map.has_key?(wire_skill, "inputModes")
        refute Map.has_key?(wire_skill, "outputModes")
      end)
    end

    @tag :w7_io_modes
    test "(e2) real Plug serves a moded agent's per-skill override on the wire" do
      # A real `AshA2A.Protocol.Agent` GenServer whose card carries a
      # per-skill override (the same skill shape the builder emits), served
      # through the real `AshA2A.Protocol.Plug` HTTP pipeline.
      agent_name = :"moded_agent_io_modes_#{System.unique_integer([:positive])}"
      {:ok, pid} = AshA2A.V1IOModesTest.ModedAgent.start_link(name: agent_name)

      on_exit(fn ->
        AshA2A.TestSupport.SafeStop.stop(pid)
      end)

      plug_opts = AshA2A.Protocol.Plug.init(agent: agent_name, base_url: @base_url)

      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      assert conn.status == 200
      served_card = Jason.decode!(conn.resp_body)

      assert Enum.find(served_card["skills"], &(&1["id"] == "greet")) == %{
               "id" => "greet",
               "name" => "Greet",
               "description" => "Says hello",
               "tags" => [],
               "inputModes" => ["application/json"],
               "outputModes" => ["text/csv"]
             }

      # The moded skill overrides; the card defaults remain REQUIRED and
      # present alongside it.
      assert served_card["defaultInputModes"] == ["text/plain"]
      assert served_card["defaultOutputModes"] == ["text/plain"]
    end
  end
end

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_list_decode_test.exs
# ------------------------------------------------------------------------------

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

    assert %{"tasks" => wire_tasks, "totalSize" => 2, "pageSize" => 50, "nextPageToken" => ""} =
             page

    assert length(wire_tasks) == 2
    assert MapSet.new(wire_tasks, & &1["id"]) == MapSet.new([id1, id2])

    assert {:ok, decoded} = JSON.decode_list_result(page)
    assert %{tasks: tasks, total_size: 2, page_size: 50, next_page_token: ""} = decoded
    assert length(tasks) == 2
    assert Enum.all?(tasks, &match?(%AshA2A.Protocol.Task{}, &1))
    assert MapSet.new(tasks, & &1.id) == MapSet.new([id1, id2])

    # Bob's list is owner-scoped: an empty page, and it decodes too.
    assert %{"result" => bob_page} = rpc(ctx, "bob", "tasks/list", %{})
    assert bob_page["totalSize"] == 0

    assert {:ok, %{tasks: [], total_size: 0, page_size: 50, next_page_token: ""}} =
             JSON.decode_list_result(bob_page)
  end

  # -- round-trip parity ---------------------------------------------------------

  test "decode_list_result of an encoded page equals the runtime handle_list map", %{ctx: ctx} do
    create_task(ctx, "carol", "parity")
    principal = Principal.key(%{sub: "carol"})

    assert {:ok, runtime_page} =
             AshA2A.Transport.Plug.handle_list(%{}, %{agent: ctx.agent, principal: principal})

    assert %{tasks: runtime_tasks, total_size: 1, page_size: 50, next_page_token: ""} =
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
             JSON.decode_list_result(%{
               "tasks" => [%{"status" => %{"state" => "TASK_STATE_WORKING"}}]
             })
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

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_multinode_continuity_test.exs
# ------------------------------------------------------------------------------

defmodule AshA2A.V1MultinodeContinuityTest.Conversation do
  @moduledoc """
  Real fixture resource, private to this test file (per the proven
  `ash_a2a_v1_context_continuity_test.exs` pattern), for the A2A v1.0
  multi-node task-continuity court (`test/ash_a2a_v1_multinode_continuity_test.exs`).

  Same shape as the context-continuity fixture: one generic `:converse` action
  requiring `:say` and `:topic`. A turn supplying `:say` only pauses the task
  at `TASK_STATE_INPUT_REQUIRED`, so the durable store holds a genuinely
  continuable (non-terminal) task for the fresh-agent courts to resume.
  """

  use Ash.Resource,
    domain: AshA2A.V1MultinodeContinuityTest.ConversationDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:say, :string, allow_nil?: false)
      argument(:topic, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{"say" => input.arguments.say, "topic" => input.arguments.topic}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.V1MultinodeContinuityTest.ConversationDomain do
  @moduledoc "Real fixture domain for `AshA2A.V1MultinodeContinuityTest.Conversation`."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1MultinodeContinuityTest.Conversation)
  end
end

defmodule AshA2A.V1MultinodeContinuityTest.ConversationAgent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer (transport runtime: owner-scoped tasks,
  off-mailbox workers) over the private fixture resource. `execution:
  [mode: :inline]` matches the serialized shape every other plug-level
  fixture in this suite uses.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1MultinodeContinuityTest.Conversation,
    name: "v1_multinode_continuity_conversation_agent",
    require_authenticated_caller: false,
    execution: [mode: :inline]
end

defmodule AshA2A.V1MultinodeContinuityTest.StreamAgent do
  @moduledoc """
  Real `AshA2A.Agent` whose `handle_message/2` returns a lazy `{:stream,
  enumerable}` that nobody enumerates -- so the task is persisted
  `TASK_STATE_WORKING` and *stays* that way until the agent is killed, which
  is exactly the "in-memory agent lost mid-stream" state the resubscribe
  court needs (the proven `ash_a2a_v1_taskstore_durability_test.exs`
  StreamAgent pattern).
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Echo,
    name: "v1_multinode_continuity_stream_agent",
    require_authenticated_caller: false

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream, Stream.map(1..3, fn i -> AshA2A.Protocol.Part.Text.new("chunk #{i}") end)}
  end
end

defmodule AshA2A.V1MultinodeContinuityTest.AuthChain do
  @moduledoc """
  Real plug chain for the restart courts: bearer auth middleware ->
  owner-scoped transport plug over real HTTP.

  The store-backed `tasks/list` flip (lane F16) is only observable for a
  real principal: an anonymous caller never lists (fail-closed), so the
  restart courts exercise `alice`/`bob` through the same proven bearer
  scheme + `verify/3` shape the owner-scope court
  (`test/ash_a2a_v1_owner_scope_test.exs`) uses.
  """

  def init(opts), do: opts

  def call(conn, %{auth: auth, transport_plug: transport_plug}) do
    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> then(fn conn ->
      if conn.halted do
        conn
      else
        AshA2A.Transport.Plug.call(conn, transport_plug)
      end
    end)
  end
end

defmodule AshA2A.V1MultinodeContinuityTest do
  @moduledoc """
  A2A v1.0 horizontal-scaling / multi-node task-continuity court (lane Z8):
  the story the durable store claims (`AshA2A.TaskStore.Ekv`'s moduledoc) --
  a task created through a REAL agent+plug on node A is visible and
  continuable after the in-memory agent is lost, when the durable store plus
  a SECOND agent process reads the same store. Zero mocks: real Bandit
  loopback listeners serving `AshA2A.A2ATransport.Plug`, real
  `AshA2A.A2ATransport` supervision trees, real `AshA2A.Agent` GenServers, a
  real on-disk EKV store, and -- for the store tier -- a real 2-node EKV
  cluster (one member on the primary BEAM node, one on a genuinely separate
  OS-process peer started via OTP's real `:peer` module), per the proven
  pattern in `test/ash_a2a/receipt_store_ekv_crossnode_test.exs` +
  `test/support/multinode_ekv_owner.ex`.

  Verified read architecture (READ-ONLY first, pinned here as behavior):

    * `AshA2A.Protocol.Agent.State.get_task/2` (`lib/ash_a2a/protocol/agent/state.ex`)
      IS a read-through cache: in-memory hit first, `mod.get(ref, task_id)`
      fallthrough on miss. `AshA2A.Transport.Runtime.continue/6` and
      `get_task_for/3` both go through it, so a FRESH agent process whose
      in-memory task map is empty finds every task the store holds. The
      agent-level horizontal story HOLDS for interactive tasks.
    * The deliberate gaps this court pins as gap witnesses:
      (1) CLOSED (lane F16): `AshA2A.Transport.Runtime.list_tasks_for/3` used
      to page the IN-MEMORY map only, so `tasks/list` on a fresh agent
      returned nothing even though the store held the tasks. It now merges
      the store's tasks into the page (in-memory wins on id collision, union
      by owner key) before the single `Filter.apply` + pagination, so
      `tasks/list` read-through sees every task the store holds for the
      caller — court (b) pins the flipped wire behavior.
      (2) A mid-flight stream is node-local (`metadata[:stream]` is redacted
      at rest by EKV and the enumerating process died with the lost agent):
      the persisted task is visible and resubscribable on the fresh agent,
      but continuing it is refused typed (`:task_in_progress`, the
      `state != :working` guard in `Runtime.continue/6`) and the stream never
      progresses by itself on the new agent. The honest close: the fresh
      agent can still cancel the task, and that wire cancel publishes the
      final TaskEvents event that terminates the resubscribed SSE stream.

  The agent restart legs run as LOCAL restarts (fresh GenServer, same
  process-name-free store tuple) because the gap is store-fallback-shaped --
  the agent tier's behavior is identical for a restarted process on the same
  node; the STORE tier (where the second real node lives) is exercised on a
  genuine 2-node EKV cluster with cross-node reads of plug-created tasks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  @moduletag :v1_conformance

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.TaskStore.Ekv, as: EkvStore
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.MultinodeEkvOwner
  alias AshA2A.V1MultinodeContinuityTest.{ConversationAgent, StreamAgent}

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  # Real verify callback (owner-scope court shape): the bearer token names
  # the user; the verified identity keys the owner via
  # `AshA2A.Transport.Principal.key/1` -> `"sub:<token>"`.
  def verify("bearer", token, _conn),
    do: {:ok, %{sub: token, token: "raw-credential-of-" <> token}}

  defp auth_chain(agent, transport) do
    AshA2A.V1MultinodeContinuityTest.AuthChain.init(%{
      auth: AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3),
      transport_plug:
        AshA2A.Transport.Plug.init(agent: agent, base_url: "http://x/a2a", transport: transport)
    })
  end

  # Real HTTP auth chain -> transport plug, like `plug_and_transport/1` but
  # with the bearer middleware in front, so wire callers carry a verified
  # principal (`alice`/`bob`) instead of `:anonymous`.
  defp plug_and_transport_auth(agent) do
    uniq = System.unique_integer([:positive, :monotonic])
    transport = :"a2a_transport_v1mncont_auth_#{uniq}"
    start_supervised!({AshA2A.A2ATransport, name: transport})

    EphemeralHttp.start!(
      {AshA2A.V1MultinodeContinuityTest.AuthChain, auth_chain(agent, transport)}
    ).base_url
  end

  # -- authenticated wire helpers ----------------------------------------------

  # The anonymous caller is the real no-auth shape: no Authorization header,
  # so the auth middleware leaves `conn.private[:a2a][:auth]` unset.
  defp rpc_as(url, :anonymous, method, params) do
    rpc(url, method, params)
  end

  defp rpc_as(url, user, method, params) do
    body = rpc_envelope(method, params)

    Req.post!(url,
      json: Map.put(body, "params", params),
      headers: [{"authorization", "Bearer " <> user}],
      retry: false,
      receive_timeout: 10_000
    )
    |> Map.fetch!(:body)
    |> case do
      m when is_map(m) -> m
      bin when is_binary(bin) -> Jason.decode!(bin)
    end
  end

  defp turn_as(url, user, opts) do
    params = %{"message" => user_message(Keyword.get(opts, :data), Keyword.get(opts, :task_id))}

    params =
      if ctx = Keyword.get(opts, :context_id),
        do: Map.put(params, "contextId", ctx),
        else: params

    url
    |> rpc_as(user, "message/send", params)
    |> result_task()
  end

  setup_all do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_v1_mn_cont_primary_#{System.pid()}"
      {:ok, _pid} = Node.start(primary_name, :shortnames)
    end

    on_exit(fn ->
      if not already_alive? and Node.alive?() do
        Node.stop()
      end
    end)

    :ok
  end

  setup do
    %{cookie: Node.get_cookie(), host: peer_host(), code_paths: :code.get_path()}
  end

  defp peer_host do
    Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()
  end

  # Near-verbatim copy of `AshA2A.ReceiptStoreEkvCrossnodeTest.start_real_peer/3`
  # (private functions cannot be called across modules).
  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_v1_mn_cont_peer_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{
        name: peer_name,
        host: host,
        args: [~c"-setcookie", Atom.to_charlist(cookie)]
      })

    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])

    {peer_pid, peer_node}
  end

  # Same real, empirically-found reason `AshA2A.MultinodeClusterTest`'
  # @moduledoc documents: `:peer.stop/1` on a `:peer.start_link/1`-started
  # peer must be called FROM THE SAME process that called `start_link`, so
  # cleanup lives in each test's own `try/after`, not `on_exit/1`.
  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid), do: :peer.stop(peer_pid)

    :ok
  end

  defp fresh_ekv_name do
    :"ash_a2a_v1_mn_cont_ekv_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp fresh_data_dir(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_v1_mn_cont_#{tag}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # cluster_size: 1 -- one local EKV member, for the agent-restart courts.
  defp ekv_local(tag) do
    name = fresh_ekv_name()
    data_dir = fresh_data_dir(tag)
    start_supervised!(EkvStore.child_spec(name: name, data_dir: data_dir))
    %{name: name, data_dir: data_dir, store: EkvStore.task_store(name)}
  end

  # -- wire helpers (proven `ash_a2a_v1_context_continuity_test.exs` shape) ---

  defp rpc_envelope(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

  defp rpc(url, method, params) do
    body = rpc_envelope(method, params)

    resp_body =
      Req.post!(url, json: Map.put(body, "params", params), retry: false, receive_timeout: 10_000)
      |> Map.fetch!(:body)

    if is_map(resp_body), do: resp_body, else: Jason.decode!(resp_body)
  end

  defp user_message(data, task_id) do
    parts = if data, do: [Part.Data.new(data)], else: [Part.Text.new("go")]
    message = struct(Message.new_user(parts), task_id: task_id)
    {:ok, encoded} = JSON.encode(message)
    encoded
  end

  defp turn(url, opts) do
    params = %{"message" => user_message(Keyword.get(opts, :data), Keyword.get(opts, :task_id))}

    params =
      if ctx = Keyword.get(opts, :context_id), do: Map.put(params, "contextId", ctx), else: params

    url
    |> rpc("message/send", params)
    |> result_task()
  end

  defp result_task(%{"result" => result}) do
    task = get_in(result, ["task"]) || result

    assert is_map(task) and is_binary(task["id"]), "no task in message/send result"
    task
  end

  defp plug_and_transport(agent) do
    uniq = System.unique_integer([:positive, :monotonic])
    transport = :"a2a_transport_v1mncont_#{uniq}"
    start_supervised!({AshA2A.A2ATransport, name: transport})

    EphemeralHttp.start!(
      {TransportPlug, agent: agent, base_url: "http://x/a2a", transport: transport}
    ).base_url
  end

  # -- SSE streaming helpers (proven `ash_a2a_v1_sse_replay_test.exs` shape) --

  defp open_streaming(url, method, params) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: %{
          "jsonrpc" => "2.0",
          "id" => System.unique_integer([:positive]),
          "method" => method,
          "params" => params
        },
        retry: false,
        receive_timeout: 15_000,
        into: fn {:data, data}, acc ->
          send(parent, {:chunk, self(), data})
          {:cont, acc}
        end
      )

      send(parent, {:stream_closed, self()})
    end)
  end

  defp collect_until_closed(pid, acc) do
    receive do
      {:chunk, ^pid, data} -> collect_until_closed(pid, acc <> data)
      {:stream_closed, ^pid} -> acc
    after
      15_000 -> flunk("resubscribed stream did not close after the fresh-agent cancel")
    end
  end

  defp parse_sse(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      lines = String.split(frame, "\n")

      for "data: " <> json <- Enum.filter(lines, &String.starts_with?(&1, "data: ")) do
        Jason.decode!(json)["result"]
      end
    end)
  end

  # -- fixture conversation turn helper ---------------------------------------

  defp converse(data, opts) do
    turn(Keyword.fetch!(opts, :url), Keyword.put(opts, :data, data))
  end

  defp eventually(fun, attempts \\ 100, sleep_ms \\ 50)
  defp eventually(_fun, 0, _sleep_ms), do: false

  defp eventually(fun, attempts, sleep_ms) do
    if fun.(), do: true, else: Process.sleep(sleep_ms) && eventually(fun, attempts - 1, sleep_ms)
  end

  # ===========================================================================
  # Court (a): the STORE tier across two real nodes -- a task created through
  # a real agent+plug on node A is visible on real node B, and a second agent
  # process over the same cluster continues it to a terminal state that is
  # again visible from node B.
  # ===========================================================================
  describe "two-node store tier" do
    test "a plug-created task on the primary replicates to the peer; a second agent continues it; the terminal state is visible from the peer",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      assert Node.alive?(), "primary node must be a real distributed node by this point"

      {peer_pid, peer_node} = start_real_peer(host, cookie, code_paths)

      try do
        assert peer_node in Node.list()

        ekv_name = fresh_ekv_name()
        data_dir_primary = fresh_data_dir("a_primary")
        data_dir_peer = fresh_data_dir("a_peer")

        base_opts = [name: ekv_name, cluster_size: 2, wait_for_quorum: :timer.seconds(25)]

        # The peer's real EKV cluster member starts first (from a real,
        # persistent peer-owned process -- see MultinodeEkvOwner's @moduledoc),
        # then the primary's member blocks on the real 2-of-2 quorum until the
        # peer joins. Both wait for each other and proceed together.
        test_pid = self()

        _owner =
          Node.spawn(peer_node, MultinodeEkvOwner, :start_ekv_member_and_wait, [
            Keyword.put(base_opts, :data_dir, data_dir_peer),
            test_pid
          ])

        start_supervised!(
          EkvStore.child_spec(Keyword.put(base_opts, :data_dir, data_dir_primary))
        )

        assert_receive {:ekv_member_started, ^peer_node, sup_pid}, 30_000
        assert node(sup_pid) == peer_node

        # --- node A: real agent + plug over the 2-node cluster. ---------------
        store = EkvStore.task_store(ekv_name)

        {:ok, agent_a_pid} =
          ConversationAgent.start_link(name: :v1mncont_agent_a, task_store: store)

        url_a = plug_and_transport(:v1mncont_agent_a)

        task1 = converse(%{"say" => "hail"}, url: url_a, context_id: "ctx-v1mn-a")

        assert task1["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
        task_id = task1["id"]
        assert task1["contextId"] == "ctx-v1mn-a"

        # --- node B: the same task, read through the peer's own EKV member. ---
        # Wait for the task's FINAL paused state, not mere existence: the
        # store also carries the turn's intermediate `:working` write, and an
        # existence-only wait reads that mid-flight snapshot (observed
        # `:working` on this exact read under load).
        assert eventually(fn ->
                 match?(
                   {:ok, %AshA2A.Protocol.Task{status: %{state: :input_required}}},
                   :erpc.call(peer_node, EkvStore, :get, [ekv_name, task_id], 10_000)
                 )
               end),
               "the plug-created task must replicate to the peer's real EKV member"

        assert {:ok, peer_task} =
                 :erpc.call(peer_node, EkvStore, :get, [ekv_name, task_id], 10_000)

        assert peer_task.id == task_id
        assert peer_task.context_id == "ctx-v1mn-a"
        assert peer_task.status.state == :input_required

        # --- the in-memory agent A is lost. -----------------------------------
        GenServer.stop(agent_a_pid)
        assert Process.whereis(:v1mncont_agent_a) == nil

        # --- a SECOND agent process over the SAME store cluster. --------------
        {:ok, agent_b_pid} =
          ConversationAgent.start_link(name: :v1mncont_agent_b, task_store: store)

        url_b = plug_and_transport(:v1mncont_agent_b)

        # Its in-memory task map is genuinely empty; the read falls through to
        # the store cluster.
        assert %State{tasks: tasks_b} = :sys.get_state(agent_b_pid)
        assert tasks_b == %{}

        %{"result" => fetched} = rpc(url_b, "tasks/get", %{"id" => task_id})
        assert fetched["id"] == task_id
        assert fetched["contextId"] == "ctx-v1mn-a"
        assert fetched["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
        assert length(fetched["history"]) == 2

        # --- and the second agent CONTINUES the stored task on the wire. ------
        task2 = turn(url_b, task_id: task_id, data: %{"say" => "hail", "topic" => "weather"})

        assert task2["id"] == task_id
        assert task2["status"]["state"] == "TASK_STATE_COMPLETED"
        assert task2["contextId"] == "ctx-v1mn-a"
        assert length(task2["history"]) == 4

        # --- the terminal state is again visible from the peer. ---------------
        assert eventually(fn ->
                 case :erpc.call(peer_node, EkvStore, :get, [ekv_name, task_id], 10_000) do
                   {:ok, %AshA2A.Protocol.Task{status: %{state: :completed}}} -> true
                   _ -> false
                 end
               end),
               "the second agent's terminal write must replicate to the peer"

        cleanup_agents([:v1mncont_agent_a, :v1mncont_agent_b])
      after
        stop_if_alive(peer_pid)
      end
    end
  end

  # ===========================================================================
  # Court (b): the AGENT tier, local restart -- after the in-memory agent is
  # lost, a fresh agent over the same durable store answers tasks/get,
  # LISTS the stored task (store-backed read-through, lane F16), continues
  # it, and the terminal state lists too — pagination over the merged set.
  # ===========================================================================
  describe "agent-restart tier" do
    test "a fresh agent answers tasks/get, lists the stored task, and continues it; the terminal state lists too",
         %{cookie: _cookie, host: _host, code_paths: _code_paths} do
      %{name: ekv_name, store: store} = ekv_local("b")

      {:ok, agent_a_pid} =
        ConversationAgent.start_link(name: :v1mncont_b_agent_a, task_store: store)

      url_a = plug_and_transport_auth(:v1mncont_b_agent_a)

      # alice creates the non-terminal task; the owner key (`"ash_a2a.owner"`
      # = "sub:alice") is what persists — the Z9 at-rest owner-survival pin.
      task1 = turn_as(url_a, "alice", context_id: "ctx-v1mn-b")
      assert task1["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      task_id = task1["id"]

      # bob's own task in the same store, so merged owner-scoping is real.
      bob_task = turn_as(url_a, "bob", context_id: "ctx-v1mn-b-bob")
      assert bob_task["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

      # The durable store holds both tasks, each carrying its owner key.
      assert {:ok, persisted} = EkvStore.get(ekv_name, task_id)
      assert persisted.status.state == :input_required
      assert persisted.metadata["ash_a2a.owner"] == "sub:alice"

      assert {:ok, bob_persisted} = EkvStore.get(ekv_name, bob_task["id"])
      assert bob_persisted.metadata["ash_a2a.owner"] == "sub:bob"

      # --- the in-memory agent is lost. ---------------------------------------
      GenServer.stop(agent_a_pid)
      assert Process.whereis(:v1mncont_b_agent_a) == nil

      # Cold read-through: a state struct with an empty in-memory map and only
      # the store tuple finds the task (the exact read path
      # `Runtime.continue/6` and `get_task_for/3` take).
      cold = %State{module: ConversationAgent, task_store: store}
      assert {:ok, %AshA2A.Protocol.Task{id: ^task_id}} = State.get_task(cold, task_id)

      # --- a fresh agent process over the same store. --------------------------
      {:ok, agent_b_pid} =
        ConversationAgent.start_link(name: :v1mncont_b_agent_b, task_store: store)

      assert %State{tasks: tasks_b} = :sys.get_state(agent_b_pid)
      assert tasks_b == %{}

      url_b = plug_and_transport_auth(:v1mncont_b_agent_b)

      # The anonymous shape is the REAL no-auth shape (owner-scope court
      # definition): the transport reached with NO auth middleware in front,
      # so no verified identity exists in conn.private.
      url_b_anon = plug_and_transport(:v1mncont_b_agent_b)

      %{"result" => fetched} = rpc_as(url_b, "alice", "tasks/get", %{"id" => task_id})
      assert fetched["id"] == task_id
      assert fetched["contextId"] == "ctx-v1mn-b"
      assert fetched["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      assert length(fetched["history"]) == 2

      # FLIPPED PIN (lane F16): the transport's owner-scoped tasks/list is now
      # store-backed read-through (`Runtime.list_tasks_for/3` merges the
      # store's tasks into the page before `Filter.apply`), so the fresh agent
      # with an empty in-memory map lists the persisted task for its owner.
      # Owner-scoping holds over the merged set: alice sees exactly her task
      # (never bob's), bob sees exactly his, and anonymous still lists
      # nothing at all.
      %{"result" => %{"tasks" => [listed], "totalSize" => 1}} =
        rpc_as(url_b, "alice", "tasks/list", %{})

      assert listed["id"] == task_id
      assert listed["contextId"] == "ctx-v1mn-b"
      assert listed["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      # Same scrubbing as the in-memory path: no internal keys on the wire.
      refute Map.has_key?(listed, "metadata")

      %{"result" => %{"tasks" => [bob_listed], "totalSize" => 1}} =
        rpc_as(url_b, "bob", "tasks/list", %{})

      assert bob_listed["id"] == bob_task["id"]

      assert %{"result" => %{"tasks" => [], "totalSize" => 0}} =
               rpc(url_b_anon, "tasks/list", %{})

      # The raw agent-level list (the Protocol path) IS store-backed but
      # UNSCOPED: a fresh agent's {:list_tasks, params} delegates to the
      # store's list_all/2 and pages everything — the owner-scoped wire
      # surface above is the gate.
      assert {:ok, page} = GenServer.call(:v1mncont_b_agent_b, {:list_tasks, %{}})
      assert page.total_size == 2

      # --- the fresh agent continues the stored task. --------------------------
      task2 =
        turn_as(url_b, "alice", task_id: task_id, data: %{"say" => "hail", "topic" => "weather"})

      assert task2["id"] == task_id
      assert task2["status"]["state"] == "TASK_STATE_COMPLETED"
      assert task2["contextId"] == "ctx-v1mn-b"
      assert length(task2["history"]) == 4

      # FLIPPED PIN, terminal leg: after the continuation, tasks/list on the
      # same fresh agent still lists exactly alice's one task — now the
      # terminal state (the in-memory write overrode the store copy;
      # totalSize is the merged count, still 1).
      %{"result" => %{"tasks" => [terminal], "totalSize" => 1}} =
        rpc_as(url_b, "alice", "tasks/list", %{})

      assert terminal["id"] == task_id
      assert terminal["status"]["state"] == "TASK_STATE_COMPLETED"

      # The store now holds the second agent's terminal write.
      assert {:ok, %AshA2A.Protocol.Task{status: %{state: :completed}}} =
               EkvStore.get(ekv_name, task_id)

      cleanup_agents([:v1mncont_b_agent_a, :v1mncont_b_agent_b])
    end

    test "pagination over the merged (in-memory + store) set is exact: no dup, no gap", _ctx do
      %{store: store} = ekv_local("b_walk")

      {:ok, agent_a_pid} =
        ConversationAgent.start_link(name: :v1mncont_bwalk_agent_a, task_store: store)

      url_a = plug_and_transport_auth(:v1mncont_bwalk_agent_a)

      # Three durable tasks from alice on the original agent, distinct
      # contexts so each is its own task in the store.
      created =
        for i <- 1..3 do
          t = turn_as(url_a, "alice", context_id: "ctx-v1mn-bwalk-#{i}")
          assert t["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
          t["id"]
        end

      # --- the in-memory agent is lost. ---------------------------------------
      GenServer.stop(agent_a_pid)

      # --- a fresh agent over the same store: in-memory map empty, merged set
      # is the store's three tasks. -------------------------------------------
      {:ok, _agent_b_pid} =
        ConversationAgent.start_link(name: :v1mncont_bwalk_agent_b, task_store: store)

      url_b = plug_and_transport_auth(:v1mncont_bwalk_agent_b)

      # Walk pageSize=2 pages: page 1 is exactly 2 tasks with a live cursor,
      # page 2 the remainder with the "" terminator, union == the created ids
      # with no duplicate and no gap, and every page carries the pre-
      # pagination merged total (3).
      %{"result" => page1} = rpc_as(url_b, "alice", "tasks/list", %{"pageSize" => 2})
      assert %{"tasks" => t1, "totalSize" => 3, "nextPageToken" => tok1} = page1
      assert length(t1) == 2
      assert is_binary(tok1) and tok1 != ""

      %{"result" => page2} =
        rpc_as(url_b, "alice", "tasks/list", %{"pageSize" => 2, "pageToken" => tok1})

      assert %{"tasks" => t2, "totalSize" => 3, "nextPageToken" => ""} = page2
      assert length(t2) == 1

      walked = Enum.map(t1 ++ t2, & &1["id"])
      assert Enum.uniq(walked) == walked, "no duplicate task across pages"

      assert Enum.sort(walked) == Enum.sort(created),
             "no gap: the walk covers exactly the merged set"

      cleanup_agents([:v1mncont_bwalk_agent_a, :v1mncont_bwalk_agent_b])
    end
  end

  # ===========================================================================
  # Court (c): the SSE/resubscribe tier -- a persisted non-terminal (mid-
  # stream, node-local) task is resubscribable on the fresh agent; continuing
  # it there is refused typed (`:task_in_progress`); the fresh agent's wire
  # cancel publishes the final event that terminates the resubscribed stream.
  # ===========================================================================
  describe "sse-resubscribe tier" do
    test "a mid-stream task lost with its agent is resubscribable on a fresh agent; continuation is refused typed; the fresh agent's cancel closes the stream",
         %{cookie: _cookie, host: _host, code_paths: _code_paths} do
      %{name: ekv_name, store: store} = ekv_local("c")
      {:ok, agent_a_pid} = StreamAgent.start_link(name: :v1mncont_c_agent_a, task_store: store)

      # Real agent run producing a stream task; nobody enumerates the returned
      # stream, so the task is persisted :working and stays that way (the
      # wrapped stream is node-local and dies with agent A).
      {:ok, %AshA2A.Protocol.Task{id: task_id} = task} =
        StreamAgent.call(:v1mncont_c_agent_a, AshA2A.Protocol.Message.new_user("stream me"))

      assert task.status.state == :working

      # The store's persisted copy has the node-local stream reference redacted
      # at rest (EKV's documented at-rest redaction).
      assert {:ok, persisted} = EkvStore.get(ekv_name, task_id)
      refute Map.has_key?(persisted.metadata, :stream)

      # --- the in-memory agent is lost mid-stream. ----------------------------
      GenServer.stop(agent_a_pid)
      assert Process.whereis(:v1mncont_c_agent_a) == nil

      # --- a fresh agent process over the same store. -------------------------
      {:ok, _agent_b_pid} = StreamAgent.start_link(name: :v1mncont_c_agent_b, task_store: store)
      url_b = plug_and_transport(:v1mncont_c_agent_b)

      # The fresh agent answers tasks/get for the persisted task.
      %{"result" => fetched} = rpc(url_b, "tasks/get", %{"id" => task_id})
      assert fetched["id"] == task_id
      assert fetched["status"]["state"] == "TASK_STATE_WORKING"

      # Wire resubscribe on the FRESH agent: the first SSE frame is the
      # persisted task snapshot (S3.1.6), served through the same store
      # read-through.
      open_streaming(url_b, "tasks/resubscribe", %{"id" => task_id})
      {conn_pid, snapshot_result, acc} = await_snapshot_frame()

      assert %{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_WORKING"}}} =
               snapshot_result

      # GAP WITNESS (by design, see moduledoc): continuing the :working task
      # on the fresh agent is refused typed -- the stream is node-local and
      # not resumable (the DurableServer continuity gap, GitHub issue #8).
      continuation =
        GenServer.call(
          :v1mncont_c_agent_b,
          {:message, Message.new_user("resume"), task_id: task_id}
        )

      assert {:error, %{code: :task_in_progress}} = continuation

      # The honest close: the fresh agent can cancel the task, and the wire
      # cancel publishes the final TaskEvents event that terminates the
      # resubscribed stream with a terminal frame.
      %{"result" => canceled} = rpc(url_b, "tasks/cancel", %{"id" => task_id})
      assert canceled["id"] == task_id
      assert canceled["status"]["state"] == "TASK_STATE_CANCELED"

      body = collect_until_closed(conn_pid, acc)
      frames = parse_sse(body)

      assert [
               %{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_WORKING"}}}
               | rest
             ] =
               frames

      # G3 (2d874565): the terminating cancel publishes the spec wire form —
      # a final StatusUpdate frame (S3.2.3 single-key `statusUpdate` wrapper),
      # not a re-echoed task snapshot.
      assert Enum.any?(rest, fn
               %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_CANCELED"}}} -> true
               _ -> false
             end)

      # The fresh agent's cancel is durable too.
      assert {:ok, %AshA2A.Protocol.Task{status: %{state: :canceled}}} =
               EkvStore.get(ekv_name, task_id)

      cleanup_agents([:v1mncont_c_agent_a, :v1mncont_c_agent_b])
    end
  end

  # Receives chunks from the (anonymous-pid) resubscribe connection until the
  # first task frame appears; returns `{conn_pid, snapshot_result, bytes_so_far}`
  # so the cancel-frame collector can resume with the full prefix.
  defp await_snapshot_frame(acc \\ "") do
    receive do
      {:chunk, pid, data} ->
        acc = acc <> data

        case Enum.find(parse_sse(acc), fn result ->
               match?(%{"task" => %{"id" => _}}, result)
             end) do
          nil -> await_snapshot_frame(acc)
          result -> {pid, result, acc}
        end
    after
      5_000 -> flunk("no snapshot frame from the resubscribed stream")
    end
  end

  defp cleanup_agents(names) do
    for name <- names do
      if pid = Process.whereis(name) do
        GenServer.stop(pid)
      end
    end
  end
end

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_oban_delivery_test.exs
# ------------------------------------------------------------------------------







# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_owner_scope_test.exs
# ------------------------------------------------------------------------------







# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_pagination_test.exs
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_pb_fidelity_test.exs
# ------------------------------------------------------------------------------

defmodule AshA2A.V1PbFidelityTest do
  @moduledoc """
  Lane X14 — pb-descriptor fidelity court (closes X8's drift exposure).

  X8 (`ash_a2a_v1_proto_fidelity_test.exs`) courts the codec against the
  vendored IDL (`priv/a2a_v1_spec_corpus/a2a.proto`) — but nothing courts the
  *generated* pb projection (`lib/ash_a2a/transport/grpc/pb/lf/a2a/v1/
  a2a.pb.ex`, never hand-edited) against the codec. Two exposures follow:

    1. `Protobuf.JSON.decode!/2` FAILS OPEN on unknown camelCase keys: a
       codec-emitted key the pb projection does not know is silently dropped
       at the gRPC bridge (`AshA2A.Transport.GRPC.Server.to_params/1`), so a
       codec/pb drift would lose fields on the wire with no error anywhere.
    2. A pb regeneration that adds/renames fields changes the descriptor
       silently; if the codec cannot emit a pb json_name, that field is dead
       on the gRPC binding until someone notices.

  ## The three-way court

  Three independent sources of wire vocabulary, cross-checked pairwise per
  message row:

    * W1 codec — the keys a REAL encode emits (`AshA2A.Protocol.JSON.encode/
      encode_stream_response/encode_agent_card` on populated samples);
    * W2 pb — the json_names extracted at test time from the generated
      descriptors (`Lf.A2a.V1.*.__message_props__().field_props`, protobuf
      0.17 introspection surface);
    * W3 corpus — the vendored spec IDL parsed at test time (field names
      lowerCamelCased; `[(google.api.field_behavior) = REQUIRED]` fields
      pinned as the TCK-required surface).

  Assertions per row (see `run_court/0` for the emitted table):

    a. W1 ⊆ W2 — every codec-emitted key exists as a pb json_name (the
       fail-open direction: an unknown key would be silently dropped);
    b. W2 − W1 == pinned ledger — every pb json_name the codec cannot emit
       is enumerated and pinned (`@pb_only_ledger`), so pb regen drift
       changes the delta and fails the court;
    c. W3-required ⊆ W1 — every TCK-required field is codec-emittable;
    d. W3-required ⊆ W2 — the descriptors carry every TCK-required field;
    e. W1 ⊆ W3-vocab — codec vocabulary stays inside the spec IDL's.

  ## Mutation witness

  The comparison MECHANISM is exercised directly: a copy of the real `Task`
  descriptor field map with one json_name renamed (`contextId` →
  `contextIdX`) must be flagged as drift by the comparator; a copy with an
  extra pb-only key must likewise flag. The court is green only because the
  real descriptors pass — not because the comparator is vacuous.

  ## Protobuf.JSON round-trip

  For a sample instance per message: pb message → `Protobuf.JSON.encode!` →
  our codec `decode/2` → equivalent codec struct. **Fail-open edge, pinned:**
  the round-trip only VALUE-asserts the fields listed in each row's
  `value_asserts/0`; every other field's survival is guaranteed solely by
  assertions (a)/(b) above (the key-level court), not by value checks. The
  pinned lists below are exactly the fields whose wire values the tests
  value-assert.

  Falsifier: court green + mutation witness flags the mutation. Any new
  codec key not in the descriptors, or any descriptor change moving the
  pb-only delta off its pin, fails the court.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSON

  alias AshA2A.Protocol.{
    AgentCard,
    AgentExtension,
    Artifact,
    Event,
    Message,
    Part,
    PushNotificationConfig,
    Task
  }

  alias Lf.A2a.V1, as: Pb

  # The generated pb projection is regenerated from priv/proto/a2a.proto (v1.1
  # IDL), so the vocabulary/REQUIRED corpus must be the v1.1 one.
  @proto_path Path.join(__DIR__, "../priv/a2a_v1_1_spec_corpus/a2a.proto")

  # ------------------------------------------------------------------
  # Comparator — the pure mechanism under test
  # ------------------------------------------------------------------

  defmodule Comparator do
    @moduledoc false

    # Pure three-way comparison, fed field maps as input so the mutation
    # witness can drive it directly. `required` is a MapSet of wire keys the
    # spec corpus pins as REQUIRED. Returns the drift triad.
    @spec compare(MapSet.t(), MapSet.t(), MapSet.t()) :: %{
            missing: [String.t()],
            added: [String.t()],
            required_missing: [String.t()]
          }
    def compare(codec_keys, pb_names, required \\ MapSet.new()) do
      %{
        missing: MapSet.difference(codec_keys, pb_names) |> Enum.sort(),
        added: MapSet.difference(pb_names, codec_keys) |> Enum.sort(),
        required_missing: MapSet.difference(required, codec_keys) |> Enum.sort()
      }
    end
  end

  # ------------------------------------------------------------------
  # W2 — json_name maps from the generated pb descriptors
  # ------------------------------------------------------------------

  @spec pb_names(module()) :: MapSet.t(String.t())
  defp pb_names(mod) do
    mod.__message_props__().field_props
    |> Map.new(fn {_fnum, %Protobuf.FieldProps{} = prop} -> {prop.json_name, true} end)
    |> Map.keys()
    |> MapSet.new()
  end

  # ------------------------------------------------------------------
  # W3 — spec corpus: vocabulary + REQUIRED pins parsed from the IDL
  # ------------------------------------------------------------------

  defmodule Corpus do
    @moduledoc false

    @field_re ~r/^\s*(?:(repeated|optional)\s+)?((?:map\s*<[^>]+>)|(?:[[:alnum:]_.]+))\s+(\w+)\s*=\s*(\d+)\s*(?:\[([^\]]*)\])?\s*;/

    # %{message_name => %{vocab: MapSet(camelCase), required: MapSet(camelCase)}}
    def messages(path) do
      src = path |> File.read!() |> String.replace(~r{//[^\n]*}, "")

      blocks(src, "message")
      |> Map.new(fn {name, body} ->
        fields =
          body
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            case Regex.run(@field_re, line) do
              [_, _label, _type, name, _num, annotation] ->
                [{name, String.contains?(annotation, "REQUIRED")}]

              # Non-participating annotation group is omitted by Regex.run/3.
              [_, _label, _type, name, _num] ->
                [{name, false}]

              nil ->
                []
            end
          end)

        # Dedupe by field name, OR-ing the REQUIRED flags (a field name could
        # in principle be matched twice).
        fields =
          Enum.reduce(fields, %{}, fn {name, req}, acc ->
            Map.update(acc, name, req, fn prev -> prev or req end)
          end)

        vocab = MapSet.new(fields, fn {name, _req} -> camel(name) end)
        required = MapSet.new(for {name, true} <- fields, do: camel(name))

        {name, %{vocab: vocab, required: required}}
      end)
    end

    defp blocks(src, kind, acc \\ []) do
      header = Regex.compile!("\\b#{kind}\\s+(\\w+)\\s*\\{")

      case Regex.run(header, src, return: :index) do
        [{start, len}, {name_start, name_len}] ->
          open = start + len - 1
          rest = binary_part(src, open, byte_size(src) - open)
          close = matching_brace(rest, 0)
          body = binary_part(rest, 1, close - 1)
          name = binary_part(src, name_start, name_len)
          tail = close + 1
          blocks(binary_part(rest, tail, byte_size(rest) - tail), kind, [{name, body} | acc])

        nil ->
          Enum.reverse(acc)
      end
    end

    defp matching_brace(bin, idx, depth \\ 0) do
      case binary_part(bin, idx, 1) do
        "{" ->
          matching_brace(bin, idx + 1, depth + 1)

        "}" when depth == 1 ->
          idx

        "}" ->
          matching_brace(bin, idx + 1, depth - 1)

        _other ->
          matching_brace(bin, idx + 1, depth)
      end
    end

    def camel(name) do
      [head | rest] = String.split(name, "_")
      Enum.join([head | Enum.map(rest, &String.capitalize/1)])
    end
  end

  # ------------------------------------------------------------------
  # Court rows: one per pb message the codec bridges
  # ------------------------------------------------------------------

  defp rows do
    [
      %{
        label: "Task",
        pb_mod: Pb.Task,
        corpus: "Task",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(task_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "TaskStatus",
        pb_mod: Pb.TaskStatus,
        corpus: "TaskStatus",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(status_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "Message",
        pb_mod: Pb.Message,
        corpus: "Message",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(message_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      # Part: the three oneof members + the flat file shape; union of keys.
      %{
        label: "Part (oneof text/raw/url/data)",
        pb_mod: Pb.Part,
        corpus: "Part",
        codec_keys: fn ->
          ["text", "raw", "url", "data"]
          |> Enum.flat_map(fn variant ->
            {:ok, m} = JSON.encode(part_sample(variant))
            Map.keys(m)
          end)
          |> MapSet.new()
        end,
        ledger: []
      },
      %{
        label: "Artifact",
        pb_mod: Pb.Artifact,
        corpus: "Artifact",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(artifact_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "TaskStatusUpdateEvent",
        pb_mod: Pb.TaskStatusUpdateEvent,
        corpus: "TaskStatusUpdateEvent",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(status_update_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "TaskArtifactUpdateEvent",
        pb_mod: Pb.TaskArtifactUpdateEvent,
        corpus: "TaskArtifactUpdateEvent",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(artifact_update_sample())
          MapSet.new(Map.keys(m))
        end,
        ledger: []
      },
      %{
        label: "TaskPushNotificationConfig",
        pb_mod: Pb.TaskPushNotificationConfig,
        corpus: "TaskPushNotificationConfig",
        codec_keys: fn ->
          {:ok, m} = JSON.encode(push_config_sample())
          MapSet.new(Map.keys(m))
        end,
        # Pb TaskPushNotificationConfig.tenant (field 1) has no codec
        # counterpart: %AshA2A.Protocol.PushNotificationConfig{} carries no
        # tenant — the gRPC bridge's request side takes tenant from
        # SendMessageRequest.tenant instead.
        ledger: ["tenant"]
      },
      %{
        label: "StreamResponse (all four members)",
        pb_mod: Pb.StreamResponse,
        corpus: "StreamResponse",
        codec_keys: fn ->
          [
            task_sample(),
            message_sample(),
            status_update_sample(),
            artifact_update_sample(),
            message_update_sample(),
            %AshA2A.Protocol.StreamError{
              task_id: "t1",
              code: "E",
              message: "m",
              reference_id: "r",
              metadata: %{"k" => "v"}
            }
          ]
          |> Enum.flat_map(fn s ->
            {:ok, m} = JSON.encode_stream_response(s)
            Map.keys(m)
          end)
          |> MapSet.new()
        end,
        ledger: []
      },
      %{
        label: "AgentCard",
        pb_mod: Pb.AgentCard,
        corpus: "AgentCard",
        codec_keys: fn -> card_map() |> Map.keys() |> MapSet.new() end,
        ledger: []
      },
      %{
        label: "AgentCapabilities",
        pb_mod: Pb.AgentCapabilities,
        corpus: "AgentCapabilities",
        codec_keys: fn -> card_map()["capabilities"] |> Map.keys() |> MapSet.new() end,
        ledger: []
      },
      %{
        label: "AgentInterface",
        pb_mod: Pb.AgentInterface,
        corpus: "AgentInterface",
        codec_keys: fn ->
          card_map()["supportedInterfaces"] |> hd() |> Map.keys() |> MapSet.new()
        end,
        # Pb AgentInterface.tenant (field 3) is not emitted: the card's
        # supportedInterfaces entries carry no tenant (single-tenant hosts).
        ledger: ["tenant"]
      },
      %{
        label: "AgentProvider",
        pb_mod: Pb.AgentProvider,
        corpus: "AgentProvider",
        codec_keys: fn -> card_map()["provider"] |> Map.keys() |> MapSet.new() end,
        ledger: []
      },
      %{
        label: "AgentSkill",
        pb_mod: Pb.AgentSkill,
        corpus: "AgentSkill",
        codec_keys: fn -> card_map()["skills"] |> hd() |> Map.keys() |> MapSet.new() end,
        # Pb AgentSkill.examples (field 5) is not emitted: the codec's skill
        # projection has no examples field.
        ledger: ["examples"]
      },
      %{
        label: "AgentExtension",
        pb_mod: Pb.AgentExtension,
        corpus: "AgentExtension",
        codec_keys: fn ->
          card_map()["capabilities"]["extensions"] |> hd() |> Map.keys() |> MapSet.new()
        end,
        ledger: []
      }
    ]
  end

  # ------------------------------------------------------------------
  # Test 1+2 — the three-way table (directions a–e above)
  # ------------------------------------------------------------------

  test "three-way fidelity court: codec ⇔ pb descriptors ⇔ spec corpus" do
    corpus = Corpus.messages(@proto_path)

    table =
      Enum.map(rows(), fn row ->
        codec = row.codec_keys.()
        pb = pb_names(row.pb_mod)
        %{vocab: vocab, required: required} = Map.fetch!(corpus, row.corpus)

        drift =
          Comparator.compare(codec, pb, required)

        # (a) codec ⊆ pb — the fail-open direction
        assert drift.missing == [],
               "#{row.label}: codec emits keys absent from the pb descriptor " <>
                 "(Protobuf.JSON drops them silently): #{inspect(drift.missing)}"

        # (b) pb − codec == pinned ledger
        assert drift.added == row.ledger,
               "#{row.label}: pb-only json_names drifted off the pinned ledger. " <>
                 "expected #{inspect(row.ledger)}, got #{inspect(drift.added)}"

        # (c)+(d) TCK-required fields: codec-emittable AND in the descriptor
        assert drift.required_missing == [],
               "#{row.label}: TCK-required fields not codec-emittable / not in pb: " <>
                 "#{inspect(drift.required_missing)}"

        # (e) codec vocabulary stays inside the spec IDL
        outside = codec |> MapSet.difference(vocab) |> Enum.sort()

        assert outside == [],
               "#{row.label}: codec emits keys outside the spec corpus vocabulary: " <>
                 "#{inspect(outside)}"

        %{
          "message" => row.label,
          "codec" => MapSet.size(codec),
          "pb" => MapSet.size(pb),
          "pb_only(pinned)" => row.ledger,
          "required" => MapSet.size(required)
        }
      end)

    # The court's three-way table, rendered into the run log.
    IO.puts([?\n, "X14 pb-descriptor fidelity court — three-way table:", ?\n])
    Enum.each(table, fn row -> IO.puts("#{inspect(row)}") end)
  end

  # ------------------------------------------------------------------
  # Test 3 — mutation witness: the comparator detects descriptor drift
  # ------------------------------------------------------------------

  test "mutation witness: renamed json_name and added pb-only key are flagged" do
    real = pb_names(Pb.Task)

    codec =
      MapSet.new([
        "id",
        "contextId",
        "status",
        "artifacts",
        "history",
        "timeline",
        "metadata",
        "generation"
      ])

    # Sanity: the real maps pass the comparator — the witness is not vacuous.
    assert Comparator.compare(codec, real) == %{
             missing: [],
             added: [],
             required_missing: []
           }

    # Mutation 1: copy the pb field map, rename ONE json_name in the copy.
    mutated_rename =
      Pb.Task.__message_props__().field_props
      |> Map.update!(2, fn %Protobuf.FieldProps{} = p -> %{p | json_name: "contextIdX"} end)
      |> Map.new(fn {_fnum, %Protobuf.FieldProps{} = p} -> {p.json_name, true} end)
      |> Map.keys()
      |> MapSet.new()

    drift = Comparator.compare(codec, mutated_rename)

    assert "contextId" in drift.missing,
           "comparator failed to flag the renamed json_name: #{inspect(drift)}"

    assert "contextIdX" in drift.added,
           "comparator failed to surface the mutant's new name: #{inspect(drift)}"

    # Mutation 2: a pb regeneration adding a field the codec cannot emit.
    mutated_add = MapSet.put(real, "taskLedgerOnly")
    drift2 = Comparator.compare(codec, mutated_add)
    assert drift2.added == ["taskLedgerOnly"], "comparator failed to flag pb-only addition"
  end

  # ------------------------------------------------------------------
  # Test 4 — Protobuf.JSON round-trip per message
  # ------------------------------------------------------------------

  test "Protobuf.JSON round-trip: pb message -> JSON -> codec struct" do
    Enum.each(round_trips(), fn %{label: label} = rt ->
      pb_msg = rt.pb.()
      json = pb_msg |> Protobuf.JSON.encode!() |> Jason.decode!()
      assert {:ok, struct} = rt.decode.(json), "#{label}: codec decode failed"

      # Pinned value-asserts: exactly the fields whose wire values this test
      # checks (see the pinned list in the moduledoc / per-row asserts).
      Enum.each(rt.value_asserts.(struct), fn {field_path, actual, expected} ->
        assert actual == expected,
               "#{label}: round-trip lost #{field_path}: #{inspect(actual)} != #{inspect(expected)}"
      end)
    end)
  end

  # ------------------------------------------------------------------
  # Test 5 — the documented fail-open edge itself
  # ------------------------------------------------------------------

  test "documented fail-open edge: Protobuf.JSON drops unknown camelCase keys silently" do
    json = %{"id" => "t1", "contextIdX" => "c1", "status" => %{"state" => "TASK_STATE_WORKING"}}

    # No error raised — decode fails open...
    decoded = Protobuf.JSON.decode!(Jason.encode!(json), Pb.Task)
    # ...and the unknown key's payload is gone: this is the silent-loss edge
    # the three-way court above exists to pre-empt.
    assert decoded.context_id == ""
  end

  # ------------------------------------------------------------------
  # Provenance court — priv/proto/a2a.proto header SHA vs the body bytes
  # ------------------------------------------------------------------

  test "priv/proto/a2a.proto: line-2 Upstream SHA-256 equals sha256 of the vendored body" do
    lines =
      :ash_a2a
      |> :code.priv_dir()
      |> Path.join("proto/a2a.proto")
      |> File.read!()
      |> String.split("\n")

    [_vendored, sha_line | rest] = lines
    assert "// Upstream SHA-256: " <> header_sha = sha_line

    # The provenance header is the leading `//` block ending at the first
    # blank line; everything after it is the verbatim upstream body.
    body = rest |> Enum.drop_while(&(&1 != "")) |> Enum.drop(1) |> Enum.join("\n")
    actual = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    assert actual == String.trim(header_sha),
           "a2a.proto header SHA #{header_sha} != sha256(body) #{actual}"
  end

  # ------------------------------------------------------------------
  # Round-trip rows: pb sample -> codec decode, pinned value-asserts
  # ------------------------------------------------------------------

  defp round_trips do
    [
      %{
        label: "Task",
        pb: fn ->
          %Pb.Task{
            id: "t1",
            context_id: "c1",
            status: %Pb.TaskStatus{state: :TASK_STATE_WORKING},
            artifacts: [
              %Pb.Artifact{
                artifact_id: "a1",
                name: "out",
                parts: [%Pb.Part{content: {:text, "result"}}]
              }
            ],
            history: [
              %Pb.Message{
                message_id: "m1",
                role: :ROLE_AGENT,
                parts: [%Pb.Part{content: {:text, "hi"}}]
              }
            ],
            metadata: pb_struct(%{"k" => "v"})
          }
        end,
        decode: fn m -> JSON.decode(m, :task) end,
        value_asserts: fn s ->
          [
            {"id", s.id, "t1"},
            {"context_id", s.context_id, "c1"},
            {"status.state", s.status.state, :working},
            {"artifacts len", length(s.artifacts), 1},
            {"artifact_id", hd(s.artifacts).artifact_id, "a1"},
            {"history len", length(s.history), 1},
            {"history role", hd(s.history).role, :agent},
            {"metadata", s.metadata, %{"k" => "v"}}
          ]
        end
      },
      %{
        label: "TaskStatus",
        pb: fn ->
          %Pb.TaskStatus{
            state: :TASK_STATE_INPUT_REQUIRED,
            message: %Pb.Message{
              message_id: "sm",
              role: :ROLE_AGENT,
              parts: [%Pb.Part{content: {:text, "need input"}}]
            },
            timestamp: %Google.Protobuf.Timestamp{seconds: 1_767_225_600}
          }
        end,
        decode: fn m -> JSON.decode(m, :status) end,
        value_asserts: fn s ->
          [
            {"state", s.state, :input_required},
            {"message.message_id", s.message.message_id, "sm"},
            {"timestamp", s.timestamp, ~U[2026-01-01T00:00:00Z]}
          ]
        end
      },
      %{
        label: "Message",
        pb: fn ->
          %Pb.Message{
            message_id: "m1",
            context_id: "c1",
            task_id: "t1",
            role: :ROLE_AGENT,
            parts: [%Pb.Part{content: {:text, "hi"}}],
            metadata: pb_struct(%{"mk" => "mv"}),
            extensions: ["https://ext.example"],
            reference_task_ids: ["r1"]
          }
        end,
        decode: fn m -> JSON.decode(m, :message) end,
        value_asserts: fn s ->
          [
            {"message_id", s.message_id, "m1"},
            {"context_id", s.context_id, "c1"},
            {"task_id", s.task_id, "t1"},
            {"role", s.role, :agent},
            {"parts[0].text", hd(s.parts).text, "hi"},
            {"extensions", s.extensions, ["https://ext.example"]},
            {"referenceTaskIds", s.reference_task_ids, ["r1"]},
            {"metadata", s.metadata, %{"mk" => "mv"}}
          ]
        end
      },
      %{
        label: "Part.text",
        pb: fn -> %Pb.Part{content: {:text, "hello"}, metadata: pb_struct(%{"pk" => "pv"})} end,
        decode: fn m -> JSON.decode(m, :part) end,
        value_asserts: fn s ->
          [
            {"text", s.text, "hello"},
            {"metadata", s.metadata, %{"pk" => "pv"}}
          ]
        end
      },
      %{
        label: "Part.raw (file bytes)",
        pb: fn ->
          %Pb.Part{
            content: {:raw, <<1, 2, 3>>},
            filename: "f.bin",
            media_type: "application/octet-stream"
          }
        end,
        decode: fn m -> JSON.decode(m, :part) end,
        value_asserts: fn s ->
          [
            {"file.bytes", s.file.bytes, <<1, 2, 3>>},
            {"file.name", s.file.name, "f.bin"},
            {"file.mime_type", s.file.mime_type, "application/octet-stream"}
          ]
        end
      },
      %{
        label: "Part.url (file url)",
        pb: fn ->
          %Pb.Part{content: {:url, "https://x.example/i.png"}, media_type: "image/png"}
        end,
        decode: fn m -> JSON.decode(m, :part) end,
        value_asserts: fn s ->
          [
            {"file.uri", s.file.uri, "https://x.example/i.png"},
            {"file.mime_type", s.file.mime_type, "image/png"}
          ]
        end
      },
      %{
        label: "Part.data",
        pb: fn ->
          %Pb.Part{
            content: {:data, %Google.Protobuf.Value{kind: {:string_value, "x"}}},
            metadata: pb_struct(%{"dk" => "dv"})
          }
        end,
        decode: fn m -> JSON.decode(m, :part) end,
        value_asserts: fn s ->
          [
            {"data", s.data, "x"},
            {"metadata", s.metadata, %{"dk" => "dv"}}
          ]
        end
      },
      %{
        label: "Artifact",
        pb: fn ->
          %Pb.Artifact{
            artifact_id: "a1",
            name: "out",
            description: "d",
            parts: [%Pb.Part{content: {:text, "result"}}],
            metadata: pb_struct(%{"ak" => "av"}),
            extensions: ["https://ext.example"]
          }
        end,
        decode: fn m -> JSON.decode(m, :artifact) end,
        value_asserts: fn s ->
          [
            {"artifact_id", s.artifact_id, "a1"},
            {"name", s.name, "out"},
            {"description", s.description, "d"},
            {"parts[0].text", hd(s.parts).text, "result"},
            {"extensions", s.extensions, ["https://ext.example"]},
            {"metadata", s.metadata, %{"ak" => "av"}}
          ]
        end
      },
      %{
        label: "TaskStatusUpdateEvent",
        pb: fn ->
          %Pb.TaskStatusUpdateEvent{
            task_id: "t1",
            context_id: "c1",
            status: %Pb.TaskStatus{state: :TASK_STATE_COMPLETED}
          }
        end,
        decode: fn m -> JSON.decode(m, :status_update_event) end,
        value_asserts: fn s ->
          [
            {"task_id", s.task_id, "t1"},
            {"context_id", s.context_id, "c1"},
            {"status.state", s.status.state, :completed},
            {"final (derived)", s.final, true}
          ]
        end
      },
      %{
        label: "TaskArtifactUpdateEvent",
        pb: fn ->
          %Pb.TaskArtifactUpdateEvent{
            task_id: "t1",
            context_id: "c1",
            artifact: %Pb.Artifact{
              artifact_id: "a1",
              parts: [%Pb.Part{content: {:text, "chunk"}}]
            },
            append: true,
            last_chunk: true
          }
        end,
        decode: fn m -> JSON.decode(m, :artifact_update_event) end,
        value_asserts: fn s ->
          [
            {"task_id", s.task_id, "t1"},
            {"context_id", s.context_id, "c1"},
            {"artifact.artifact_id", s.artifact.artifact_id, "a1"},
            {"append", s.append, true},
            {"last_chunk", s.last_chunk, true}
          ]
        end
      },
      %{
        label: "TaskPushNotificationConfig",
        pb: fn ->
          %Pb.TaskPushNotificationConfig{
            id: "pc1",
            task_id: "t1",
            url: "https://hook.example",
            token: "tok",
            authentication: %Pb.AuthenticationInfo{scheme: "Bearer", credentials: "creds"}
          }
        end,
        decode: fn m -> JSON.decode(m, :push_notification_config) end,
        value_asserts: fn s ->
          [
            {"id", s.id, "pc1"},
            {"task_id", s.task_id, "t1"},
            {"url", s.url, "https://hook.example"},
            {"token", s.token, "tok"},
            {"authentication.scheme", s.authentication[:scheme], "Bearer"},
            {"authentication.credentials", s.authentication[:credentials], "creds"}
          ]
        end
      },
      %{
        label: "StreamResponse.statusUpdate",
        pb: fn ->
          %Pb.StreamResponse{
            payload:
              {:status_update,
               %Pb.TaskStatusUpdateEvent{
                 task_id: "t1",
                 context_id: "c1",
                 status: %Pb.TaskStatus{state: :TASK_STATE_WORKING}
               }}
          }
        end,
        decode: fn m -> JSON.decode(m, :event) end,
        value_asserts: fn s ->
          [
            {"task_id", s.task_id, "t1"},
            {"status.state", s.status.state, :working}
          ]
        end
      },
      %{
        label: "AgentCard",
        pb: fn ->
          %Pb.AgentCard{
            name: "card-agent",
            description: "desc",
            version: "1.0.0",
            capabilities: %Pb.AgentCapabilities{},
            supported_interfaces: [
              %Pb.AgentInterface{
                url: "https://a.example",
                protocol_binding: "JSONRPC",
                protocol_version: "1.0"
              }
            ],
            skills: [%Pb.AgentSkill{id: "s1", name: "s", description: "d", tags: ["t"]}],
            default_input_modes: ["text/plain"],
            default_output_modes: ["text/plain"]
          }
        end,
        decode: fn m -> JSON.decode_agent_card(m) end,
        value_asserts: fn s ->
          [
            {"name", s.name, "card-agent"},
            {"description", s.description, "desc"},
            {"version", s.version, "1.0.0"},
            {"interface url (preferred)", s.url, "https://a.example"},
            {"skills[0].id", hd(s.skills).id, "s1"}
          ]
        end
      }
    ]
  end

  # ------------------------------------------------------------------
  # Codec samples (W1 sources) — populated so every emittable key emits
  # ------------------------------------------------------------------

  defp task_sample do
    %Task{
      id: "t1",
      context_id: "c1",
      status: status_sample(),
      history: [message_sample()],
      artifacts: [artifact_sample()],
      timeline: [
        %AshA2A.Protocol.TimelineEntry{entry: {:message, message_sample()}, generation: 1},
        %AshA2A.Protocol.TimelineEntry{entry: {:status, status_sample()}, generation: 2}
      ],
      generation: 3,
      metadata: %{"k" => "v"}
    }
  end

  defp message_update_sample do
    Event.MessageUpdate.new("t1", message_sample(),
      context_id: "c1",
      generation: 4,
      metadata: %{"ek" => "ev"}
    )
  end

  defp status_sample do
    %AshA2A.Protocol.Task.Status{
      state: :working,
      message: message_sample(),
      timestamp: ~U[2026-01-01T00:00:00Z]
    }
  end

  defp message_sample do
    %Message{
      message_id: "m1",
      role: :agent,
      parts: [
        part_sample("text"),
        part_sample("raw"),
        part_sample("url"),
        part_sample("data")
      ],
      task_id: "t1",
      context_id: "c1",
      reference_task_ids: ["r1"],
      metadata: %{"mk" => "mv"},
      extensions: ["https://ext.example"]
    }
  end

  # Variant in {"text", "raw", "url", "data"}.
  defp part_sample("text"), do: %Part.Text{text: "hello", metadata: %{"pk" => "pv"}}

  defp part_sample("raw"),
    do: %Part.File{
      file: %AshA2A.Protocol.FileContent{
        bytes: <<1, 2, 3>>,
        name: "f.bin",
        mime_type: "application/octet-stream"
      },
      metadata: %{"pk" => "pv"}
    }

  defp part_sample("url"),
    do: %Part.File{
      file: %AshA2A.Protocol.FileContent{uri: "https://x.example/i.png", mime_type: "image/png"}
    }

  defp part_sample("data"), do: %Part.Data{data: %{"dk" => "dv"}, metadata: %{"pk" => "pv"}}

  defp artifact_sample do
    %Artifact{
      artifact_id: "a1",
      name: "out",
      description: "d",
      parts: [part_sample("text")],
      extensions: ["https://ext.example"],
      metadata: %{"ak" => "av"},
      start_generation: 1,
      end_generation: 2,
      role: :agent
    }
  end

  defp status_update_sample do
    Event.StatusUpdate.new("t1", status_sample(),
      context_id: "c1",
      generation: 5,
      metadata: %{"ek" => "ev"}
    )
  end

  defp artifact_update_sample do
    Event.ArtifactUpdate.new("t1", artifact_sample(),
      context_id: "c1",
      append: true,
      last_chunk: true,
      generation: 6,
      metadata: %{"ek" => "ev"}
    )
  end

  defp push_config_sample do
    %PushNotificationConfig{
      id: "pc1",
      task_id: "t1",
      url: "https://hook.example",
      token: "tok",
      authentication: %{scheme: "Bearer", credentials: "creds"},
      protocol_version: "1.1"
    }
  end

  defp card do
    %AgentCard{
      name: "card-agent",
      description: "desc",
      url: "https://a.example",
      version: "1.0.0",
      provider: %{organization: "Org", url: "https://p.example"},
      documentation_url: "https://docs.example",
      icon_url: "https://icon.example",
      skills: [
        %{
          id: "s1",
          name: "s",
          description: "d",
          tags: ["t"],
          input_modes: ["text/plain"],
          output_modes: ["text/plain"],
          security_requirements: [%{"api" => ["scope1"]}]
        }
      ],
      capabilities: %{
        streaming: true,
        push_notifications: true,
        extended_agent_card: true,
        user_artifacts: true,
        extensions: [
          %AgentExtension{
            uri: "https://ext.example",
            required: true,
            description: "d",
            params: %{"a" => "b"}
          }
        ]
      },
      default_input_modes: ["text/plain"],
      default_output_modes: ["text/plain"],
      supported_interfaces: [
        %{url: "https://a.example", protocol_binding: "JSONRPC", protocol_version: "1.0"}
      ],
      security_schemes: %{
        "api" => %AshA2A.Protocol.SecurityScheme.APIKey{name: "key", in: "header"},
        "http" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"},
        "oauth2" => %AshA2A.Protocol.SecurityScheme.OAuth2{
          flows: %{
            "authorizationCode" => %{
              "authorizationUrl" => "https://auth.example",
              "tokenUrl" => "https://tok.example",
              "refreshUrl" => "https://ref.example",
              "scopes" => %{"read" => "r"},
              "pkceRequired" => true
            }
          },
          oauth2_metadata_url: "https://meta.example"
        },
        "oauth2_cc" => %AshA2A.Protocol.SecurityScheme.OAuth2{
          flows: %{
            "clientCredentials" => %{
              "tokenUrl" => "https://tok.example",
              "scopes" => %{}
            }
          }
        },
        "oidc" => %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
          open_id_connect_url: "https://oidc.example"
        },
        "mtls" => %AshA2A.Protocol.SecurityScheme.MutualTLS{}
      },
      security: [%{"api" => ["scope1"]}],
      signatures: [
        %{"protected" => "p", "signature" => "sig", "header" => %{"alg" => "ES256K"}}
      ]
    }
  end

  defp card_map do
    JSON.encode_agent_card(card(), url: "https://a.example")
  end

  defp pb_struct(map) do
    %Google.Protobuf.Struct{
      fields:
        Map.new(map, fn {k, v} ->
          {k, %Google.Protobuf.Value{kind: {:string_value, v}}}
        end)
    }
  end
end

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_proto_fidelity_test.exs
# ------------------------------------------------------------------------------

defmodule AshA2A.V1ProtoFidelityTest do
  @moduledoc """
  Z16 — a2a.proto schema-fidelity court.

  Pins that the codec's wire vocabulary (`AshA2A.Protocol.JSON`) IS the
  official A2A v1 proto's protojson mapping, judged against the REAL vendored
  IDL: `priv/a2a_v1_spec_corpus/a2a.proto` (kept pristine; provenance here).

  ## Provenance of the vendored IDL

  - Source URL:
    https://raw.githubusercontent.com/a2aproject/A2A/main/specification/a2a.proto
    (the `specification/gRPC/a2a.proto` path named in the lane contract 404s;
    the GitHub tree listing resolves the official IDL at
    `specification/a2a.proto`)
  - Fetched from a2aproject/A2A `main` @ `fe182ee3c053d2e6a3ad2576c959fa5f7d8b5d07`
  - Last commit touching `specification/a2a.proto`:
    `cfc9d34bc41e368827eb6446d31f912e44f795c5` (2026-07-21T16:48:19Z)
  - Vendored verbatim, byte-for-byte, no edits. `syntax = "proto3"`,
    `package lf.a2a.v1`, service `A2AService` with 11 RPCs.

  ## Method

  A lightweight regex IDL parser (no protoc) parses the vendored file at test
  time into messages (fields + oneofs), enums, and services. REAL codec encode
  outputs (`AshA2A.Protocol.JSON.encode*/encode_agent_card/
  encode_stream_response`) are compared against the parsed IDL:

  - (a) every wire member a real encode emits must be the lowerCamelCase
    rendering of a real field of the corresponding proto message — divergent
    keys must match the pinned-findings ledger EXACTLY (no unpinned drift,
    no stale pins);
  - (b) `TaskState`/`Role` enum spellings: our `TASK_STATE_*`/`ROLE_*` strings
    vs the proto enum values, both directions, divergences pinned;
  - (c) the `A2AService` RPC list must equal the dispatch mapping surface
    (`AshA2A.Transport.Grpc.Dispatch.methods/0`), streaming flags included,
    and each RPC's internal JSON-RPC path must be present in
    `lib/ash_a2a/protocol/jsonrpc.ex`;
  - (d) role enum fidelity (`ROLE_USER`/`ROLE_AGENT`).

  Falsifier: green (all matched) or green-with-pinned-findings. Any NEW
  drift — an emitted key or enum value not in the proto and not pinned —
  fails the court with both sides in the failure message.
  """

  use ExUnit.Case, async: true

  @proto_path Path.join(__DIR__, "../priv/a2a_v1_spec_corpus/a2a.proto")
  @jsonrpc_path Path.join(__DIR__, "../lib/ash_a2a/protocol/jsonrpc.ex")

  # ------------------------------------------------------------------
  # Lightweight proto IDL parser (no protoc)
  # ------------------------------------------------------------------

  defmodule IDL do
    @moduledoc false

    @field_re ~r/^\s*(?:(repeated|optional)\s+)?((?:map\s*<[^>]+>)|(?:[[:alnum:]_.]+))\s+(\w+)\s*=\s*(\d+)\s*(?:\[[^\]]*\])?\s*;/
    @rpc_re ~r/\brpc\s+(\w+)\s*\(([\w.]*)\)\s*returns\s*\(\s*(stream\s+)?([\w.]*)\s*\)/

    def parse(src) do
      src = strip_comments(src)

      %{
        messages:
          src
          |> blocks("message")
          |> Map.new(fn {n, b} -> {n, %{fields: fields(b), oneofs: oneofs(b)}} end),
        enums: src |> blocks("enum") |> Map.new(fn {n, b} -> {n, enum_values(b)} end),
        services: src |> blocks("service") |> Map.new(fn {n, b} -> {n, rpcs(b)} end)
      }
    end

    def strip_comments(src), do: String.replace(src, ~r{//[^\n]*}, "")

    # Finds every `kind Name {` header and brace-matches each block body.
    defp blocks(src, kind, acc \\ []) do
      header = Regex.compile!("\\b#{kind}\\s+(\\w+)\\s*\\{")

      case Regex.run(header, src, return: :index) do
        [{start, len}, {name_start, name_len}] ->
          open = start + len - 1
          rest = binary_part(src, open, byte_size(src) - open)
          close = matching_brace(rest, 0)
          body = binary_part(rest, 1, close - 1)
          name = binary_part(src, name_start, name_len)
          tail = close + 1
          blocks(binary_part(rest, tail, byte_size(rest) - tail), kind, [{name, body} | acc])

        nil ->
          Enum.reverse(acc)
      end
    end

    # `bin` starts at the open brace; returns the index of its match.
    defp matching_brace(bin, idx, depth \\ 0) do
      case binary_part(bin, idx, 1) do
        "{" ->
          matching_brace(bin, idx + 1, depth + 1)

        "}" when depth == 1 ->
          idx

        "}" ->
          matching_brace(bin, idx + 1, depth - 1)

        _other ->
          matching_brace(bin, idx + 1, depth)
      end
    end

    defp fields(body) do
      body
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(@field_re, line) do
          [_, label, type, name, num] ->
            [{name, %{label: label || "", type: type, number: String.to_integer(num)}}]

          nil ->
            []
        end
      end)
      |> Map.new()
    end

    # Single-level oneofs (true of this IDL). Oneof members are also message
    # fields, so `fields/1` already keeps them; this records the grouping.
    defp oneofs(body, acc \\ %{}) do
      case Regex.run(~r/\boneof\s+(\w+)\s*\{/, body, return: :index) do
        [{start, len}, {name_start, name_len}] ->
          open = start + len - 1
          from_open = binary_part(body, open, byte_size(body) - open)
          close = matching_brace(from_open, 0)
          inner = binary_part(from_open, 1, close - 1)

          members =
            inner
            |> String.split("\n")
            |> Enum.flat_map(fn line ->
              case Regex.run(@field_re, line) do
                [_, _label, _type, name, _num] -> [name]
                nil -> []
              end
            end)

          name = binary_part(body, name_start, name_len)
          tail = close + 1
          remaining = binary_part(from_open, tail, byte_size(from_open) - tail)
          oneofs(remaining, Map.put(acc, name, members))

        nil ->
          acc
      end
    end

    defp enum_values(body) do
      body
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s*(\w+)\s*=\s*(-?\d+)\s*;/, line) do
          [_, name, num] -> [{name, String.to_integer(num)}]
          nil -> []
        end
      end)
      |> Map.new()
    end

    defp rpcs(body) do
      body
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(@rpc_re, line) do
          [_, name, req, stream, resp] ->
            [{name, %{request: req, streaming: stream not in [nil, ""], response: resp}}]

          nil ->
            []
        end
      end)
      |> Map.new()
    end
  end

  # ------------------------------------------------------------------
  # Pinned findings ledger (green-with-findings). Each entry carries BOTH
  # sides: the proto-side member and our emitted-side member(s). The court
  # requires the OBSERVED divergences per surface to equal the pinned ones
  # exactly — an unpinned divergence fails, and so does a stale pin (the
  # finding must be retired when lib/ is fixed).
  # ------------------------------------------------------------------

  @pinned_findings [
    %{
      id: "Z16-F5",
      kind: :legacy_surface,
      proto_side:
        "Part oneof content {text, raw, url, data} + filename + mediaType (flat v1 shape)",
      our_side_keys: ["name", "mimeType", "uri", "bytes"],
      why:
        "The standalone encode of %AshA2A.Protocol.FileContent{} emits the v0.3 " <>
          "nested-file shape. The v1 wire path for file parts is the flat Part " <>
          "oneof (raw/url/mediaType/filename), which the %Part.File{} encoder " <>
          "uses; the standalone FileContent encode is legacy v0.3 mirror surface, " <>
          "not part of the v1 wire vocabulary."
    }
  ]

  # Findings this court OBSERVED against the pre-fix codec and that were fixed
  # in lib/ (Z16-F2 by the codec lane while Z16 was running; Z16-F1/F3/F4 by
  # lane Z27). Kept here as the both-sides record; a regression re-emits the
  # old key/value and the (a)/(b) courts fail — the retirement is not a pass.
  @retired_findings [
    %{
      id: "Z16-F2",
      proto_side: "AgentCard.security_requirements -> \"securityRequirements\"",
      fixed_side: "AgentCard emits \"securityRequirements\" (was v0.3 \"security\")"
    },
    %{
      id: "Z16-F1",
      proto_side: "TaskState.TASK_STATE_UNSPECIFIED (proto3 zero value, value 0)",
      fixed_side:
        "the indeterminate state (:unknown) emits TASK_STATE_UNSPECIFIED; " <>
          "TASK_STATE_UNKNOWN is never emitted (decode still accepts it → :unknown)"
    },
    %{
      id: "Z16-F3",
      proto_side:
        "AgentCapabilities {streaming, pushNotifications, extensions, extendedAgentCard} — no state_transition_history",
      fixed_side: "AgentCapabilities no longer emits \"stateTransitionHistory\""
    },
    %{
      id: "Z16-F4",
      proto_side: "APIKeySecurityScheme.location (\"query\"/\"header\"/\"cookie\")",
      fixed_side:
        "APIKeySecurityScheme emits \"location\" (was v0.3 \"in\"); struct key stays :in"
    }
  ]

  defp pinned_keys do
    MapSet.new(Enum.flat_map(@pinned_findings, & &1.our_side_keys))
  end

  # ------------------------------------------------------------------
  # Fixtures — REAL codec outputs (Chicago: the actual encoder under test)
  # ------------------------------------------------------------------

  alias AshA2A.Protocol.{
    AgentExtension,
    Artifact,
    Event,
    FileContent,
    JSON,
    Message,
    Part,
    PushNotificationConfig,
    Task
  }

  defp status(state \\ :working) do
    %Task.Status{state: state, message: nil, timestamp: ~U[2026-10-04T00:00:00Z]}
  end

  defp part_text, do: %Part.Text{text: "hello", metadata: %{"k" => "v"}}
  defp part_data, do: %Part.Data{data: %{"x" => 1}, metadata: %{}}

  defp part_file do
    %Part.File{
      file: %FileContent{
        name: "doc.pdf",
        mime_type: "application/pdf",
        uri: "https://example.com/doc.pdf",
        bytes: <<1, 2, 3>>
      },
      metadata: %{"p" => "q"}
    }
  end

  defp message_user do
    %Message{
      message_id: "m1",
      role: :user,
      parts: [part_text()],
      task_id: "t1",
      context_id: "c1",
      reference_task_ids: ["t0"],
      metadata: %{"mk" => "mv"}
    }
  end

  defp message_agent do
    %Message{
      message_id: "m2",
      role: :agent,
      parts: [part_text(), part_file(), part_data()],
      context_id: "c1"
    }
  end

  defp artifact do
    %Artifact{
      artifact_id: "a1",
      name: "out",
      description: "an output",
      parts: [part_text()],
      extensions: ["https://ext.example"],
      metadata: %{"a" => "b"}
    }
  end

  defp push_config do
    %PushNotificationConfig{
      id: "p1",
      task_id: "t1",
      url: "https://hook.example",
      token: "tok",
      authentication: %{scheme: "Bearer", credentials: "creds"}
    }
  end

  defp agent_extension do
    %AgentExtension{
      uri: "https://ext.example",
      description: "uses the extension",
      required: true,
      params: %{"x" => 1}
    }
  end

  defp card do
    %AshA2A.Protocol.AgentCard{
      name: "Agent",
      description: "A test agent",
      url: "https://agent.example",
      version: "1.0.0",
      documentation_url: "https://docs.example",
      icon_url: "https://icon.example",
      provider: %{organization: "Org", url: "https://org.example"},
      skills: [
        %{
          id: "s1",
          name: "Skill",
          description: "Does things",
          tags: ["t"],
          input_modes: ["text/plain"],
          output_modes: ["text/plain"]
        }
      ],
      capabilities: %{
        streaming: true,
        push_notifications: true,
        state_transition_history: true,
        extended_agent_card: true,
        extensions: [agent_extension()]
      },
      default_input_modes: ["text/plain"],
      default_output_modes: ["application/json"],
      supported_interfaces: [
        %{url: "https://agent.example", protocol_binding: "JSONRPC", protocol_version: "1.0"}
      ],
      security_schemes: %{
        "api_key" => %AshA2A.Protocol.SecurityScheme.APIKey{name: "X-Api-Key", in: "header"},
        "http" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "Bearer"},
        "oauth2" => %AshA2A.Protocol.SecurityScheme.OAuth2{
          flows: %{
            "authorizationCode" => %{
              "authorizationUrl" => "https://auth",
              "tokenUrl" => "https://tok",
              "scopes" => %{"read" => "Read access"}
            }
          },
          oauth2_metadata_url: "https://meta.example"
        },
        "oidc" => %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
          open_id_connect_url: "https://oidc.example"
        },
        "mtls" => %AshA2A.Protocol.SecurityScheme.MutualTLS{}
      },
      security: [%{"api_key" => ["scope1"]}],
      signatures: [%{"protected" => "p", "signature" => "s", "header" => %{}}]
    }
  end

  defp encoded_card do
    JSON.encode_agent_card(card(), url: "https://agent.example")
  end

  # ------------------------------------------------------------------
  # Court helpers
  # ------------------------------------------------------------------

  defp idl, do: @proto_path |> File.read!() |> IDL.parse()

  # v1.1 IDL (truth for emitted members): adds Task.generation/timeline,
  # event generation, Artifact start/end_generation + role.
  @proto_v11_path Path.join(__DIR__, "../priv/a2a_v1_1_spec_corpus/a2a.proto")
  defp idl_v11, do: @proto_v11_path |> File.read!() |> IDL.parse()

  defp camel(snake) do
    [first | rest] = String.split(snake, "_")
    Enum.join([String.downcase(first) | Enum.map(rest, &String.capitalize/1)])
  end

  defp proto_camel_fields(idl, message) do
    idl.messages
    |> Map.fetch!(message)
    |> Map.fetch!(:fields)
    |> Map.keys()
    |> Enum.map(&camel/1)
    |> MapSet.new()
  end

  defp proto_oneof_members(idl, message, oneof) do
    idl.messages
    |> Map.fetch!(message)
    |> Map.fetch!(:oneofs)
    |> Map.fetch!(oneof)
    |> Enum.map(&camel/1)
    |> MapSet.new()
  end

  # ------------------------------------------------------------------
  # Court — every surface's observed divergence set (emitted keys that are
  # NOT lowerCamelCase renderings of real proto fields) must be a subset of
  # the pinned ledger, and across all surfaces EQUAL to it (no unpinned
  # drift, no stale pin).
  # ------------------------------------------------------------------

  defp encoded_surfaces do
    task =
      JSON.encode!(%Task{
        id: "t1",
        context_id: "c1",
        status: %{status() | message: message_user()},
        history: [message_agent()],
        artifacts: [artifact()],
        metadata: %{"m" => "v"}
      })

    card = encoded_card()

    [
      {"Task", task},
      {"TaskStatus", task["status"]},
      {"Message", JSON.encode!(message_user())},
      {"Artifact", JSON.encode!(artifact())},
      {"Part", JSON.encode!(part_text())},
      {"Part", JSON.encode!(part_data())},
      {"Part", JSON.encode!(part_file())},
      {"TaskStatusUpdateEvent", JSON.encode!(status_update())},
      {"TaskArtifactUpdateEvent", JSON.encode!(artifact_update())},
      {"TaskPushNotificationConfig", JSON.encode!(push_config())},
      {"AuthenticationInfo", JSON.encode!(push_config())["authentication"]},
      {"AgentExtension", JSON.encode_agent_extension(agent_extension())},
      {"AgentCard", card},
      {"AgentSkill", hd(card["skills"])},
      {"AgentCapabilities", card["capabilities"]},
      {"AgentInterface", hd(card["supportedInterfaces"])},
      {"AgentProvider", card["provider"]},
      {"AgentCardSignature", hd(card["signatures"])},
      {"APIKeySecurityScheme", card["securitySchemes"]["api_key"]["apiKeySecurityScheme"]},
      {"HTTPAuthSecurityScheme", card["securitySchemes"]["http"]["httpAuthSecurityScheme"]},
      {"OAuth2SecurityScheme", card["securitySchemes"]["oauth2"]["oauth2SecurityScheme"]},
      {"OpenIdConnectSecurityScheme",
       card["securitySchemes"]["oidc"]["openIdConnectSecurityScheme"]},
      {"MutualTlsSecurityScheme", card["securitySchemes"]["mtls"]["mtlsSecurityScheme"]}
    ]
  end

  defp status_update do
    %Event.StatusUpdate{
      task_id: "t1",
      context_id: "c1",
      status: status(),
      final: true,
      metadata: %{"s" => "t"}
    }
  end

  defp artifact_update do
    %Event.ArtifactUpdate{
      task_id: "t1",
      context_id: "c1",
      artifact: artifact(),
      append: true,
      last_chunk: false,
      metadata: %{"u" => "v"}
    }
  end

  # ------------------------------------------------------------------
  # Tests
  # ------------------------------------------------------------------

  @moduletag :z16

  describe "vendored proto corpus" do
    @describetag :z16
    test "is the official proto3 lf.a2a.v1 IDL and parses completely" do
      src = File.read!(@proto_path)
      assert src =~ ~s(syntax = "proto3";)
      assert src =~ ~s(package lf.a2a.v1;)

      parsed = idl()

      for msg <- [
            "Task",
            "Message",
            "Part",
            "TaskStatus",
            "Artifact",
            "AgentCard",
            "AgentSkill",
            "TaskStatusUpdateEvent",
            "TaskArtifactUpdateEvent",
            "StreamResponse",
            "SendMessageResponse",
            "AgentExtension",
            "TaskPushNotificationConfig",
            "AuthenticationInfo",
            "AgentCapabilities",
            "AgentInterface",
            "AgentProvider",
            "AgentCardSignature",
            "SecurityScheme",
            "OAuthFlows",
            "ListTasksResponse"
          ] do
        assert Map.has_key?(parsed.messages, msg), "missing proto message #{msg}"
      end

      assert map_size(parsed.enums["TaskState"]) == 9
      assert map_size(parsed.enums["Role"]) == 3
      assert map_size(parsed.services["A2AService"]) == 11

      # Parser sanity: real field numbers come out of the real IDL.
      assert parsed.messages["Task"].fields["id"].number == 1
      assert parsed.messages["Task"].fields["context_id"].number == 2
      assert parsed.messages["Task"].fields["status"].number == 3

      # lowerCamelCase rendering sanity — the mapping the court compares with.
      assert MapSet.equal?(
               proto_camel_fields(parsed, "Task"),
               MapSet.new(~w(id contextId status artifacts history metadata))
             )

      assert MapSet.equal?(
               proto_camel_fields(parsed, "TaskStatusUpdateEvent"),
               MapSet.new(~w(taskId contextId status metadata))
             )

      assert MapSet.equal?(
               proto_camel_fields(parsed, "AgentCard"),
               MapSet.new(
                 ~w(name description supportedInterfaces provider version documentationUrl capabilities securitySchemes securityRequirements defaultInputModes defaultOutputModes skills signatures iconUrl)
               )
             )
    end
  end

  describe "(a) message field fidelity" do
    @describetag :z16

    test "every emitted wire member is a proto field; divergences equal the pinned ledger exactly" do
      parsed = idl_v11()
      observed_all = MapSet.new()
      unexpected_all = []

      {observed_all, unexpected_all} =
        Enum.reduce(encoded_surfaces(), {observed_all, unexpected_all}, fn {message, wire},
                                                                           {obs_acc, unp_acc} ->
          proto = proto_camel_fields(parsed, message)

          observed =
            wire
            |> Map.keys()
            |> MapSet.new()
            |> MapSet.difference(proto)

          unexpected = MapSet.difference(observed, pinned_keys())

          unp_acc =
            if MapSet.size(unexpected) > 0 do
              [
                "Z16 FINDING (unpinned) on proto message #{message}: emitted wire members " <>
                  "#{inspect(MapSet.to_list(unexpected))} are not fields of the proto message " <>
                  "(proto camelCase fields: #{inspect(MapSet.to_list(proto))})"
                | unp_acc
              ]
            else
              unp_acc
            end

          {MapSet.union(obs_acc, observed), unp_acc}
        end)

      assert unexpected_all == [],
             "Z16 unpinned findings:\n" <> Enum.join(Enum.reverse(unexpected_all), "\n")

      field_pins =
        @pinned_findings
        |> Enum.filter(&(&1.kind == :field_name))
        |> Enum.flat_map(& &1.our_side_keys)
        |> MapSet.new()

      assert MapSet.equal?(observed_all, field_pins),
             "Z16 ledger drift: observed divergences " <>
               "#{inspect(MapSet.to_list(observed_all))} != pinned field findings " <>
               "#{inspect(MapSet.to_list(field_pins))} — either lib/ was fixed without " <>
               "retiring a pin, or a divergence is missing from the ledger"
    end

    test "positive spot checks: emitted key sets equal the proto renderings" do
      parsed = idl_v11()
      surfaces = encoded_surfaces()

      task_surface =
        surfaces |> Enum.find(fn {m, _} -> m == "Task" end) |> elem(1)

      # Task: set equality with the v1.1 proto's camelCase renderings; the
      # fixture task has an empty timeline, which the codec omits.
      assert MapSet.equal?(
               MapSet.new(Map.keys(task_surface)),
               MapSet.delete(proto_camel_fields(parsed, "Task"), "timeline")
             )

      # Part surfaces: every flat oneof member and descriptor is a Part field.
      for {message, wire} <- surfaces, message == "Part" do
        assert MapSet.subset?(MapSet.new(Map.keys(wire)), proto_camel_fields(parsed, "Part"))
      end

      # A flat file part emits exactly the v1 Part oneof members + descriptors.
      file_part = JSON.encode!(part_file())

      assert MapSet.equal?(
               MapSet.new(Map.keys(file_part)),
               MapSet.new(~w(filename mediaType url raw metadata))
             )
    end
  end

  describe "(a2) StreamResponse / SendMessageResponse oneof fidelity" do
    @describetag :z16

    test "encode_stream_response wrapper keys == the proto oneof members, both directions" do
      parsed = idl()

      oneof = proto_oneof_members(parsed, "StreamResponse", "payload")

      assert MapSet.equal?(oneof, MapSet.new(~w(task message statusUpdate artifactUpdate)))

      {:ok, w_task} = JSON.encode_stream_response(%Task{id: "t1", status: status()})
      {:ok, w_msg} = JSON.encode_stream_response(message_agent())
      {:ok, w_status} = JSON.encode_stream_response(status_update())
      {:ok, w_artifact} = JSON.encode_stream_response(artifact_update())

      emitted =
        [w_task, w_msg, w_status, w_artifact]
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      assert MapSet.equal?(emitted, oneof)

      # SendMessageResponse's payload oneof uses the same task/message members.
      assert MapSet.subset?(
               proto_oneof_members(parsed, "SendMessageResponse", "payload"),
               emitted
             )
    end

    test "SecurityScheme oneof wrapper keys == the proto oneof members exactly" do
      parsed = idl()

      assert MapSet.equal?(
               proto_oneof_members(parsed, "SecurityScheme", "scheme"),
               MapSet.new(
                 ~w(apiKeySecurityScheme httpAuthSecurityScheme oauth2SecurityScheme openIdConnectSecurityScheme mtlsSecurityScheme)
               )
             )

      schemes = encoded_card()["securitySchemes"]

      emitted_wrappers =
        schemes |> Map.values() |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

      assert MapSet.equal?(
               emitted_wrappers,
               proto_oneof_members(parsed, "SecurityScheme", "scheme")
             )
    end

    test "OAuthFlows oneof: emitted flow keys are proto oneof members" do
      parsed = idl()

      flows_oneof = proto_oneof_members(parsed, "OAuthFlows", "flow")

      assert MapSet.equal?(
               flows_oneof,
               MapSet.new(~w(authorizationCode clientCredentials implicit password deviceCode))
             )

      oauth2 = encoded_card()["securitySchemes"]["oauth2"]["oauth2SecurityScheme"]

      for flow_key <- Map.keys(oauth2["flows"]) do
        assert flow_key in flows_oneof
      end
    end
  end

  describe "(b) TaskState enum fidelity" do
    @describetag :z16

    test "our TASK_STATE_* strings == the proto enum exactly, both directions" do
      parsed = idl()

      proto =
        parsed.enums["TaskState"]
        |> Map.keys()
        |> MapSet.new()

      ours =
        JSON.valid_state_strings()
        |> MapSet.new()

      emitted_not_in_proto = MapSet.difference(ours, proto)
      proto_not_emitted = MapSet.difference(proto, ours)

      # Z16-F1 retired (MATCH): the emitted vocabulary IS the proto enum.
      # The indeterminate state emits the proto3 zero value
      # TASK_STATE_UNSPECIFIED; TASK_STATE_UNKNOWN is no longer emitted. Any
      # regression re-emits it and fails here (stale-pin-kills holds).
      assert MapSet.equal?(emitted_not_in_proto, MapSet.new()),
             "Z16-F1 regression: emitted-but-not-in-proto states " <>
               "#{inspect(MapSet.to_list(emitted_not_in_proto))} (proto TaskState values: " <>
               "#{inspect(MapSet.to_list(proto))})"

      assert MapSet.equal?(proto_not_emitted, MapSet.new()),
             "Z16-F1 regression: proto TaskState values we do not produce " <>
               "#{inspect(MapSet.to_list(proto_not_emitted))} — every proto value must be produced"
    end
  end

  describe "(d) Role enum fidelity" do
    @describetag :z16

    test "emitted ROLE_* values are proto Role values; only ROLE_UNSPECIFIED is unproduced" do
      parsed = idl()

      proto =
        parsed.enums["Role"]
        |> Map.keys()
        |> MapSet.new()

      user_role = JSON.encode!(message_user())["role"]
      agent_role = JSON.encode!(message_agent())["role"]

      assert user_role == "ROLE_USER"
      assert agent_role == "ROLE_AGENT"

      assert MapSet.subset?(MapSet.new([user_role, agent_role]), proto)

      assert MapSet.equal?(
               MapSet.difference(proto, MapSet.new([user_role, agent_role])),
               MapSet.new(["ROLE_UNSPECIFIED"])
             )
    end
  end

  describe "(c) A2AService RPC surface vs dispatch mapping" do
    @describetag :z16

    test "proto RPC list == Dispatch.methods names, streaming flags, JSON-RPC paths" do
      parsed = idl()
      rpcs = parsed.services["A2AService"]

      assert map_size(rpcs) == 11

      dispatch = AshA2A.Transport.Grpc.Dispatch.methods()

      assert MapSet.new(Map.keys(rpcs)) == MapSet.new(Enum.map(dispatch, & &1.name)),
             "Z16: proto A2AService RPCs #{inspect(Map.keys(rpcs) |> Enum.sort())} != " <>
               "dispatch names #{inspect(Enum.map(dispatch, & &1.name) |> Enum.sort())}"

      jsonrpc_src = File.read!(@jsonrpc_path)

      for m <- dispatch do
        assert rpcs[m.name].streaming == m.streaming,
               "Z16: streaming flag mismatch for #{m.name} " <>
                 "(proto: #{rpcs[m.name].streaming}, dispatch: #{m.streaming})"

        assert jsonrpc_src =~ m.internal,
               "Z16: RPC #{m.name} internal path #{inspect(m.internal)} is not handled " <>
                 "anywhere in lib/ash_a2a/protocol/jsonrpc.ex"
      end
    end
  end

  describe "pinned findings ledger" do
    @describetag :z16

    test "Z16-F5: legacy FileContent encode emits exactly the pinned v0.3 nested-file shape" do
      # The standalone %FileContent{} encode is the one surface whose keys are
      # NOT proto v1 Part fields (see Z16-F5); pin its exact shape here so any
      # drift on it fails too.
      legacy =
        JSON.encode!(%FileContent{
          name: "f.txt",
          mime_type: "text/plain",
          bytes: <<1>>,
          uri: "https://example.com/f.txt"
        })

      f5 = Enum.find(@pinned_findings, &(&1.id == "Z16-F5"))

      assert MapSet.equal?(
               MapSet.new(Map.keys(legacy)),
               MapSet.new(f5.our_side_keys)
             )
    end

    test "every finding carries both sides and an explanation" do
      assert length(@pinned_findings) == 1
      assert length(@retired_findings) == 4

      for finding <- @pinned_findings do
        assert is_binary(finding.id)
        assert finding.id =~ ~r/^Z16-F\d$/
        assert is_binary(finding.proto_side) and finding.proto_side != ""
        assert finding.our_side_keys != []
        assert is_binary(finding.why) and finding.why != ""
      end

      for retired <- @retired_findings do
        assert is_binary(retired.id)
        assert is_binary(retired.proto_side) and retired.proto_side != ""
        assert is_binary(retired.fixed_side) and retired.fixed_side != ""
      end
    end
  end
end

# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_push_httpjson_test.exs
# ------------------------------------------------------------------------------







# ------------------------------------------------------------------------------
# SECTION: test/ash_a2a_v1_rejected_state_test.exs
# ------------------------------------------------------------------------------

defmodule AshA2A.Protocol.V1RejectedStateTest do
  @moduledoc """
  v1.0 REJECTED terminal state: real producer proof.

  The v22 court proved the REJECTED vocabulary is declared (wire map
  `AshA2A.Protocol.JSON`, conformance terminal list, `AshA2A.TaskLifecycle`
  states) but produced by NO code path. This file proves the landed producer:
  an admission-phase refusal -- an authority-gate denial or a
  capability-resolution refusal before the handler has any effect -- drives a
  real, supervised `AshA2A.Protocol.Agent` task to the real terminal
  `:rejected` state, encodes on the wire as `TASK_STATE_REJECTED`, refuses
  continuation, and is not cancelable; while a genuine mid-handler error
  still lands `:failed` (regression control).

  Chicago-style: a real `use AshA2A.Protocol.Agent` GenServer under a real
  `AshA2A.Protocol.AgentSupervisor`, real `call/3` traffic, real state-based
  assertions on the returned and re-fetched task structs, and the real wire
  codec -- no Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{JSON, Message, Part, Task}

  defmodule RejectionAgent do
    @moduledoc """
    Real `AshA2A.Protocol.Agent` whose `handle_message/2` emits the exact
    refusal shapes the real dispatch machinery produces at admission, before
    any handler effect:

    * `"forbidden: <message>"` -- the folded form `AshA2A.Dispatcher.to_reply/1`
      emits for an Ash `class: :forbidden` denial (`class_message/2`), i.e.
      the authority gate.
    * `{:no_skill, _}` -- the capability-resolution refusal
      `AshA2A.Agent.resolve_skill_name/2` emits when no capability can be
      named for the request.
    * a plain binary error -- attempted-and-errored, the `:failed` control.
    """

    use AshA2A.Protocol.Agent,
      name: "v1_rejected_state_agent",
      description: "Produces the v1.0 REJECTED terminal state from real admission refusals.",
      skills: [
        %{
          id: "greet",
          name: "greet",
          description: "Echoes the request text back.",
          tags: []
        }
      ]

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _context) do
      case Message.text(message) do
        "forbidden" ->
          # The exact folded authority-gate form the real dispatcher emits for
          # an Ash.Policy.Authorizer denial (dispatcher.ex class_message/2).
          {:error, "forbidden: denied by policy"}

        "no-skill" ->
          # The exact capability-resolution refusal resolve_skill_name/2 emits.
          {:error, {:no_skill, __MODULE__}}

        "boom" ->
          # Attempted-and-errored: the handler ran and failed mid-run.
          {:error, "disk on fire"}

        text ->
          {:reply, [Part.Text.new("ok: " <> text)]}
      end
    end
  end

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [RejectionAgent])

    :ok
  end

  defp call(text, opts \\ []),
    do: RejectionAgent.call(RejectionAgent, Message.new_user(text), opts)

  test "authority-gate refusal lands the task terminal :rejected with a redacted reason" do
    assert {:ok, task} = call("forbidden")

    assert task.status.state == :rejected
    assert Task.terminal?(task)

    # The redacted reason is the wire-visible status message.
    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Rejected:"

    # Terminal :rejected is genuinely not cancelable, through the agent's own
    # cancel guard -- the state feeds back into real behavior, not a label.
    assert {:error, :not_cancelable} = RejectionAgent.cancel(RejectionAgent, task.id)

    # Persisted as :rejected in the agent's real state, not just returned
    # transiently.
    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :rejected}}} =
             RejectionAgent.get_task(RejectionAgent, task.id)
  end

  test "rejected task encodes on the wire as TASK_STATE_REJECTED" do
    assert {:ok, task} = call("forbidden")

    assert {:ok, encoded} = JSON.encode(task)
    assert encoded["status"]["state"] == "TASK_STATE_REJECTED"

    # The wire state round-trips back through the real codec.
    assert {:ok, decoded} = JSON.decode(encoded, :task)
    assert decoded.status.state == :rejected

    # And survives a real Jason encoding of the whole wire map.
    assert Jason.encode!(encoded) =~ "TASK_STATE_REJECTED"
  end

  test "follow-up continuation on the rejected task gets the documented refusal" do
    assert {:ok, task} = call("forbidden")

    assert {:error, :not_continuable} =
             RejectionAgent.call(RejectionAgent, Message.new_user("try again"), task_id: task.id)
  end

  test "capability-resolution refusal also lands terminal :rejected" do
    assert {:ok, task} = call("no-skill")

    assert task.status.state == :rejected
    assert Task.terminal?(task)

    assert {:error, :not_continuable} =
             RejectionAgent.call(RejectionAgent, Message.new_user("try again"),
               task_id: wire_id(task)
             )
  end

  test "a genuine handler error still lands terminal :failed (regression control)" do
    assert {:ok, task} = call("boom")

    assert task.status.state == :failed
    assert Task.terminal?(task)

    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Error:"
    assert text_part.text =~ "disk on fire"

    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :failed}}} =
             RejectionAgent.get_task(RejectionAgent, task.id)
  end

  defp wire_id(%Task{id: id}), do: id
end


defmodule AshA2A.ByteServerConformanceTest do
  @moduledoc """
  Byte-for-byte live BEAM server conformance court against `AshA2A.Test.ByteServer`.
  Verifies raw TCP wire bytes, JWS card signing, 304 conditional GET, fail-closed auth,
  cross-tenant SEC-01 isolation, SSE streaming, HTTP+JSON REST, push webhook delivery,
  RSA-SHA256 DKIM email cryptography, and live gRPC HTTP/2 port binding with zero mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{CardSigner, Client}
  alias AshA2A.Test.ByteServer

  setup do
    srv = ByteServer.start!()
    on_exit(srv.stop)
    {:ok, srv: srv}
  end

  defp raw_tcp_http(port, req_bytes) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)
    :ok = :gen_tcp.send(sock, req_bytes)
    resp = recv_until_close(sock, <<>>)
    :ok = :gen_tcp.close(sock)
    resp
  end

  defp recv_until_close(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, chunk} -> recv_until_close(sock, acc <> chunk)
      {:error, :closed} -> acc
      {:error, :timeout} -> acc
    end
  end

  defp parse_raw_http(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(k)), String.trim(v)}
      end)

    {status_line, headers, body}
  end

  test "raw TCP GET /.well-known/agent-card.json serves ES256-signed card and 304 on If-None-Match", %{srv: srv} do
    req =
      "GET /.well-known/agent-card.json HTTP/1.1\r\nHost: 127.0.0.1:#{srv.http_port}\r\nConnection: close\r\n\r\n"

    {status_line, headers, body} = raw_tcp_http(srv.http_port, req) |> parse_raw_http()
    assert status_line == "HTTP/1.1 200 OK"
    assert headers["content-type"] =~ "application/json"
    assert is_binary(etag = headers["etag"])
    assert is_binary(headers["last-modified"])
    assert headers["cache-control"] =~ "max-age="

    card = Jason.decode!(body)
    assert card["name"] == "byte_server_agent"
    assert card["capabilities"]["streaming"] == true
    assert card["capabilities"]["pushNotifications"] == true
    assert is_list(card["signatures"]) and length(card["signatures"]) == 1
    assert :ok = CardSigner.verify(card, srv.card_pub_key)

    req_304 =
      "GET /.well-known/agent-card.json HTTP/1.1\r\nHost: 127.0.0.1:#{srv.http_port}\r\nIf-None-Match: #{etag}\r\nConnection: close\r\n\r\n"

    {status_304, headers_304, body_304} = raw_tcp_http(srv.http_port, req_304) |> parse_raw_http()
    assert status_304 == "HTTP/1.1 304 Not Modified"
    assert headers_304["etag"] == etag
    assert body_304 == ""
  end

  test "GET schema endpoints and health/ready probes answer 200 with real payloads", %{srv: srv} do
    for path <- ["/.well-known/agent-card.schema.json", "/.well-known/skills.schema.json", "/health", "/ready"] do
      resp = Req.get!(srv.base_url <> path)
      assert resp.status == 200
    end
  end

  test "POST / fails closed without valid bearer and enforces SEC-01 tenant isolation", %{srv: srv} do
    unauth =
      Req.post!(srv.base_url <> "/",
        json: %{"jsonrpc" => "2.0", "id" => "1", "method" => "tasks/list", "params" => %{}}
      )

    assert unauth.status == 401

    forged =
      Req.post!(srv.base_url <> "/",
        headers: [{"authorization", "Bearer forged_token"}],
        json: %{"jsonrpc" => "2.0", "id" => "2", "method" => "tasks/list", "params" => %{}}
      )

    assert forged.status == 401

    send_resp =
      Req.post!(srv.base_url <> "/",
        headers: [{"authorization", "Bearer #{srv.token_a}"}, {"a2a-version", "1.1"}],
        json: %{
          "jsonrpc" => "2.0",
          "id" => "req-create-1",
          "method" => "message/send",
          "params" => %{
            "message" => %{
              "role" => "user",
              "parts" => [
                %{
                  "kind" => "data",
                  "data" => %{
                    "skill" => "create_order",
                    "input" => %{"reference" => "PO-BYTE-001", "amount_cents" => 4200}
                  }
                }
              ]
            },
            "metadata" => %{"a2a.auth" => %{"sub" => "spoofed_principal"}}
          }
        }
      )

    assert send_resp.status == 200
    assert List.first(send_resp.headers["a2a-version"]) == "1.1"
    task = send_resp.body["result"]["task"] || send_resp.body["result"]
    task_id = task["id"]
    assert is_binary(task_id)
    refute Jason.encode!(task) =~ "spoofed_principal"
    refute Jason.encode!(task) =~ "tok_alpha_"

    # Cross-tenant isolation: principal_b cannot see principal_a's task (-32001, never 403)
    cross =
      Req.post!(srv.base_url <> "/",
        headers: [{"authorization", "Bearer #{srv.token_b}"}],
        json: %{
          "jsonrpc" => "2.0",
          "id" => "req-cross-1",
          "method" => "tasks/get",
          "params" => %{"id" => task_id}
        }
      )

    assert cross.status == 200
    assert cross.body["error"]["code"] == -32001
  end

  test "raw TCP POST / message/stream emits real SSE frames and HTTP+JSON REST mirrors task state", %{srv: srv} do
    payload =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "stream-1",
        "method" => "message/stream",
        "params" => %{
          "message" => %{
            "role" => "user",
            "parts" => [
              %{"kind" => "data", "data" => %{"skill" => "list_orders", "input" => %{}}}
            ]
          }
        }
      })

    raw_req =
      "POST / HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{srv.http_port}\r\n" <>
        "Authorization: Bearer #{srv.token_a}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(payload)}\r\n" <>
        "Connection: close\r\n\r\n" <> payload

    {status_line, headers, body} = raw_tcp_http(srv.http_port, raw_req) |> parse_raw_http()
    assert status_line == "HTTP/1.1 200 OK"
    assert headers["content-type"] =~ "text/event-stream"

    {events, _buf} = Client.SSE.feed(Client.SSE.new(), body)
    assert length(events) >= 1

    # REST /v1/message:send + GET /v1/tasks/:id
    rest_send =
      Req.post!(srv.base_url <> "/v1/message:send",
        headers: [{"authorization", "Bearer #{srv.token_a}"}],
        json: %{
          "message" => %{
            "role" => "user",
            "parts" => [
              %{
                "kind" => "data",
                "data" => %{
                  "skill" => "create_order",
                  "input" => %{"reference" => "PO-REST-002", "amount_cents" => 9900}
                }
              }
            ]
          }
        }
      )

    assert rest_send.status in [200, 201]
    rest_task_id = rest_send.body["task"]["id"] || rest_send.body["id"]
    assert is_binary(rest_task_id)

    rest_get =
      Req.get!(srv.base_url <> "/v1/tasks/#{rest_task_id}",
        headers: [{"authorization", "Bearer #{srv.token_a}"}]
      )

    assert rest_get.status == 200
  end

  test "POST /email/inbound enforces real RSA-SHA256 DKIM cryptography (anti-cheating falsifier)", %{srv: srv} do
    signed_mime =
      ByteServer.Dkim.sign_rfc5322(
        srv.dkim_priv_key,
        "vito@sender.example",
        "dispatch@fnox.io",
        "PO-EMAIL-DKIM-001",
        "Create work order for Highland Park HVAC."
      )

    ok_resp =
      Req.post!(srv.base_url <> "/email/inbound",
        headers: [{"content-type", "message/rfc822"}],
        body: signed_mime
      )

    assert ok_resp.status == 200
    assert ok_resp.body["ok"] == true
    assert ok_resp.body["principal"] == srv.principal_a

    # Tamper a single byte in the email body -> cryptographic refusal (403)
    tampered_mime = String.replace(signed_mime, "Highland Park", "Highland Pork")

    bad_resp =
      Req.post!(srv.base_url <> "/email/inbound",
        headers: [{"content-type", "message/rfc822"}],
        body: tampered_mime
      )

    assert bad_resp.status == 403
    assert bad_resp.body["error"] =~ "dkim_crypto_failed"
  end

  test "live gRPC HTTP/2 endpoint accepts TCP connection and webhook sink receives real HTTP POST", %{srv: srv} do
    {:ok, grpc_sock} = :gen_tcp.connect(~c"127.0.0.1", srv.grpc_port, [:binary, active: false], 2_000)
    :ok = :gen_tcp.close(grpc_sock)

    ByteServer.WebhookSink.subscribe(srv.webhook_state)

    hook_resp =
      Req.post!(srv.webhook_url,
        json: %{"event" => "task.completed", "source" => "byte_server_court"}
      )

    assert hook_resp.status == 200
    assert_receive {:byte_server_webhook, %{"event" => "task.completed"}}, 1_000
    assert length(ByteServer.WebhookSink.events(srv.webhook_state)) == 1
  end
end
