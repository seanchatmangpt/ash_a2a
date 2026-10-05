defmodule AshA2AV1OwnerScopeTest.Converse do
  @moduledoc """
  Real fixture resource, private to this lane, for the v1.0 owner-scoping
  conformance court (`AshA2AV1OwnerScopeTest`).

  Its one generic `:converse` action requires `:say`, so a `message/send`
  without structured arguments pauses the real task at
  `TASK_STATE_INPUT_REQUIRED` (a continuable, non-terminal task) and the
  follow-up carrying `{"say": ...}` completes it. That gives every court a
  real foreign-owned, still-live task to attack.
  """

  use Ash.Resource,
    domain: AshA2AV1OwnerScopeTest.Domain,
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

    # Real streaming skill: the dispatcher drives a read through the real
    # `Ash.stream!/2` (`run_read_stream/4` -> `{:stream, parts}`), so
    # `message/stream` on this skill produces real SSE frames (task snapshot
    # + one ArtifactUpdate per record + final StatusUpdate) through the
    # wrapper transport. Rows are seeded by the courts that need content.
    # (A generic action's `{:stream_ok, enum}` reply is NOT a supported
    # dispatcher route -- it fails the task with an internal_error.)
    read :stream_chunks do
      primary? true
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
    skill(:stream_chunks, :stream_chunks)
  end
end

defmodule AshA2AV1OwnerScopeTest.Domain do
  @moduledoc "Real fixture domain for `AshA2AV1OwnerScopeTest.Converse`."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2AV1OwnerScopeTest.Converse)
  end
end

defmodule AshA2AV1OwnerScopeTest.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer (transport runtime: owner-keyed tasks,
  CSPRNG ids, auth rebinding) serving the fixture resource.

  `require_authenticated_caller: true` (the v1.0 default, pinned explicitly)
  plus `execution: [mode: :inline]` (serialized shape, matching every other
  plug-level fixture in this suite).
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2AV1OwnerScopeTest.Converse,
    name: "v1_owner_scope_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule AshA2AV1OwnerScopeTest.Receiver do
  @moduledoc false
  # Real webhook receiver forwarding each request body to the test process.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, body})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2AV1OwnerScopeTest do
  @moduledoc """
  A2A v1.0 owner-scoping conformance court over the real wrapper transport.

  Consolidates the owner-scoping security surface into one court per v1.0
  multi-principal semantics. Everything is real: real
  `AshA2A.Protocol.Plug.Auth` bearer middleware (a real `verify/3` callback
  whose verified identities deliberately carry a raw credential, so any echo
  is observable on the wire), real `AshA2A.A2ATransport.Plug`, real
  `AshA2A.Agent` GenServer (`AshA2A.Transport.Runtime` task state), a real
  Bandit webhook receiver on loopback. Zero mocks.

  v1.0 semantics under court:

    * A task the verified caller does not own is answered exactly like a
      missing one (`-32001`, `ErrorInfo` reason `TASK_NOT_FOUND`), so task
      existence is never revealed across principals.
    * Ownership derives only from the *verified* identity
      (`AshA2A.Transport.Principal` over `conn.private[:a2a][:auth]`), never
      from caller-supplied `params.metadata`.
    * Every payload the transport publishes is scrubbed of the verified
      auth (`"a2a.auth"`), the owner key (`"ash_a2a.owner"`) and the stream
      reference (`:stream`) -- recursively, in tasks, SSE frames and webhook
      bodies.
    * Task ids are 128-bit CSPRNG (`tsk-` + url-safe base64), so a foreign
      task cannot be guessed any more than it can be enumerated.
    * An anonymous caller on a `require_authenticated_caller` agent is
      refused and can never list.
  """

  use ExUnit.Case, async: true

  @moduletag :serial

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  # Internal metadata that must never reach any published payload.
  # "stream" is special: it is internal ONLY as a metadata-map key (the
  # in-flight enum ref the transport stamps). A user's own data part may
  # legitimately carry a "stream" key (e.g. the dispatcher's stream flag),
  # so the scanner scopes that check to metadata objects.
  @internal_keys ["a2a.auth", "ash_a2a.owner"]
  @metadata_internal_keys ["a2a.auth", "ash_a2a.owner", "stream"]

  # Real verify callback: the bearer token names the user; the verified
  # identity deliberately carries the raw credential, as real JWT/OIDC
  # identities often do, so an echo of "a2a.auth" is wire-observable.
  def verify("bearer", token, _conn),
    do: {:ok, %{sub: token, token: "raw-credential-of-" <> token}}

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"v1_owner_scope_#{uniq}"
    transport = :"a2a_transport_v1owner_#{uniq}"

    start_supervised!({AshA2AV1OwnerScopeTest.Agent, name: agent})

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport, push: [allow_http: true, allow_cidrs: ["127.0.0.1/32"], max_attempts: 1]}
    )

    hook = EphemeralHttp.start!({AshA2AV1OwnerScopeTest.Receiver, %{test: self()}})

    %{
      agent: agent,
      transport: transport,
      hook: hook.base_url <> "/hook",
      auth: AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3),
      plug:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true
        ),
      scoped_plug:
        AshA2A.Transport.Plug.init(agent: agent, base_url: "http://x/a2a")
    }
  end

  # -- wire helpers ------------------------------------------------------------

  # Real chain: bearer auth middleware -> wrapper transport plug. The
  # anonymous caller is the real no-auth shape: a request that reaches the
  # transport with no verified identity in `conn.private` (no/absent auth
  # middleware, or an exempt path), not a stub.
  defp call(ctx, :anonymous, method, params), do: plug_call(ctx, nil, method, params)

  defp call(ctx, user, method, params) do
    conn = plug_call(ctx, user, method, params)
    refute conn.halted, "auth middleware halted for #{user}"
    conn
  end

  defp plug_call(ctx, user, method, params) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => System.unique_integer([:positive]),
        "method" => method, "params" => params})

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> then(&if(is_binary(user),
        do: Plug.Conn.put_req_header(&1, "authorization", "Bearer " <> user),
        else: &1
      ))
      |> maybe_auth(ctx, user)

    TransportPlug.call(conn, ctx.plug)
  end

  defp maybe_auth(conn, _ctx, nil), do: conn

  defp maybe_auth(conn, ctx, _user),
    do: AshA2A.Protocol.Plug.Auth.call(conn, ctx.auth)

  defp rpc(ctx, user, method, params),
    do: call(ctx, user, method, params).resp_body |> Jason.decode!()

  # Encoded v1.0 wire user message naming one of the fixture's real skills
  # (two skills on the resource, so an unnamed message is ambiguous),
  # optionally carrying structured arguments and a continuation `taskId`.
  defp skill_message(skill, data \\ nil, task_id \\ nil) do
    parts = if data, do: [Part.Data.new(data)], else: [Part.Text.new("go")]
    msg = struct(Message.new_user(parts), task_id: task_id, metadata: %{"skill" => skill})
    {:ok, encoded} = JSON.encode(msg)
    encoded
  end

  defp message(extra \\ %{}) do
    Map.merge(skill_message("converse"), extra)
  end

  # One real `message/send` turn; returns the wire task (`result.task`).
  defp send_task(ctx, user, params) do
    assert %{"result" => result} = rpc(ctx, user, "message/send", params)
    get_in(result, ["task"]) || result
  end

  # Creates a fresh INPUT_REQUIRED (live, continuable) task owned by `user`.
  defp create_task(ctx, user, extra_params \\ %{}) do
    send_task(ctx, user, Map.put(extra_params, "message", message()))
  end

  # Recursively asserts no transport-internal metadata key survives anywhere
  # in a decoded wire payload (tasks, SSE frames, webhook bodies alike).
  defp assert_no_internal_keys(term, path)

  defp assert_no_internal_keys(%{} = term, path) do
    Enum.each(term, fn
      {"metadata", value} when is_map(value) ->
        # The :stream enum ref rides only as a metadata key; a user's own
        # data payload may legitimately contain a "stream" key.
        Enum.each(value, fn {k, _v} ->
          refute k in @metadata_internal_keys,
                 "internal metadata key #{inspect(k)} leaked at #{path}.metadata"
        end)

        assert_no_internal_keys(value, path <> ".metadata")

      {key, value} when is_binary(key) ->
        refute key in @internal_keys, "internal key #{inspect(key)} leaked at #{path}"

        assert_no_internal_keys(value, path <> "." <> key)

      {_key, value} ->
        assert_no_internal_keys(value, path)
    end)
  end

  defp assert_no_internal_keys(term, path) when is_list(term),
    do: term |> Enum.with_index() |> Enum.each(fn {v, i} ->
      assert_no_internal_keys(v, "#{path}[#{i}]")
    end)

  defp assert_no_internal_keys(_scalar, _path), do: :ok

  # -32001 with canonical ErrorInfo, exactly like a genuinely unknown task.
  defp assert_task_not_found(response, label) do
    assert %{
             "error" => %{
               "code" => -32_001,
               "data" => [%{"domain" => "a2a-protocol.org", "reason" => "TASK_NOT_FOUND"}]
             }
           } = response,
           "#{label} did not answer -32001 TASK_NOT_FOUND (got: #{inspect(response)})"
  end

  describe "(a) foreign tasks are -32001 TASK_NOT_FOUND on every task-naming method" do
    test "bob naming alice's task is refused, indistinguishable from an unknown task", ctx do
      %{"id" => task_id} = create_task(ctx, "alice")

      foreign_attempts = [
        {"tasks/get", %{"id" => task_id}},
        {"tasks/cancel", %{"id" => task_id}},
        {"tasks/resubscribe", %{"id" => task_id}},
        {"tasks/pushNotificationConfig/set",
         %{"taskId" => task_id, "pushNotificationConfig" => %{"url" => ctx.hook}}},
        {"tasks/pushNotificationConfig/get", %{"id" => task_id}},
        {"tasks/pushNotificationConfig/list", %{"id" => task_id}},
        {"tasks/pushNotificationConfig/delete",
         %{"id" => task_id, "pushNotificationConfigId" => "c1"}},
        {"message/send", %{"message" => message(%{"taskId" => task_id})}},
        {"message/stream", %{"message" => message(%{"taskId" => task_id})}}
      ]

      for {method, params} <- foreign_attempts do
        assert_task_not_found(rpc(ctx, "bob", method, params), "#{method} as bob")
      end

      # Indistinguishability: a foreign task and a genuinely unknown task
      # produce byte-identical error maps.
      for {method, params} <- [{"tasks/get", %{"id" => task_id}},
                               {"tasks/cancel", %{"id" => task_id}},
                               {"tasks/pushNotificationConfig/get", %{"id" => task_id}}] do
        foreign = rpc(ctx, "bob", method, params)
        unknown = rpc(ctx, "bob", method, Map.put(params, "id", "tsk-no-such-task-000"))

        assert foreign["error"] == unknown["error"],
               "#{method}: foreign vs unknown task errors differ"
      end

      # None of bob's attempts disturbed alice's task.
      assert %{"result" => %{"id" => ^task_id}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => task_id})
    end
  end

  describe "(b) the owner's own methods succeed on her task" do
    test "get, cancel, push-config CRUD, resubscribe, list and continuation all serve alice",
         ctx do
      # -- get + resubscribe on a live task
      live = create_task(ctx, "alice")
      %{"id" => live_id} = live

      assert %{"result" => %{"id" => ^live_id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => live_id})

      resub = call(ctx, "alice", "tasks/resubscribe", %{"id" => live_id})
      assert resub.resp_body =~ live_id
      assert resub.resp_body =~ ~s("state":"TASK_STATE_INPUT_REQUIRED")

      # -- list: alice's own list succeeds and carries her task (list
      #    isolation itself is courted in describe (g) over the owner-scoped
      #    transport surface)
      assert %{"result" => %{"tasks" => listed}} = rpc(ctx, "alice", "tasks/list", %{})
      assert live_id in Enum.map(listed, & &1["id"])

      # -- push-config CRUD round-trip on her own task
      assert %{"result" => %{"taskId" => ^live_id, "pushNotificationConfig" => %{"id" => cfg_id}}} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/set", %{
                 "taskId" => live_id,
                 "pushNotificationConfig" => %{"url" => ctx.hook}
               })

      assert %{"result" => %{"pushNotificationConfig" => %{"id" => ^cfg_id}}} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/get", %{
                 "id" => live_id,
                 "pushNotificationConfigId" => cfg_id
               })

      # (url round-trips too; pinned loosely to keep the court on ownership,
      # not on the webhook policy's URL normalization)

      assert %{"result" => [%{"taskId" => ^live_id, "pushNotificationConfig" => %{"id" => ^cfg_id}}]} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/list", %{"id" => live_id})

      assert %{"result" => nil} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/delete", %{
                 "id" => live_id,
                 "pushNotificationConfigId" => cfg_id
               })

      assert %{"result" => []} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/list", %{"id" => live_id})

      # -- continuation completes the task with the action's real output
      completed =
        send_task(ctx, "alice", %{
          "message" => skill_message("converse", %{"say" => "finish"}, live_id)
        })

      assert completed["id"] == live_id
      assert completed["status"]["state"] == "TASK_STATE_COMPLETED"
      assert [%{"parts" => [part]}] = completed["artifacts"]
      assert part["data"] == %{"say" => "finish"}

      # -- cancel on a separate fresh task
      %{"id" => cancel_id} = create_task(ctx, "alice")

      assert %{"result" => %{"id" => ^cancel_id, "status" => %{"state" => "TASK_STATE_CANCELED"}}} =
               rpc(ctx, "alice", "tasks/cancel", %{"id" => cancel_id})
    end
  end

  describe "(c) params.metadata forgery is dead on arrival" do
    test "forged a2a.auth / ash_a2a.owner never change who owns what", ctx do
      forged = %{
        "metadata" => %{
          "a2a.auth" => %{"identity" => %{"sub" => "alice"}},
          "ash_a2a.owner" => "sub:alice"
        }
      }

      # bob creates a task carrying forged alice identity/owner metadata: it
      # is still bob's task.
      bob_task = create_task(ctx, "bob", forged)
      task_id = bob_task["id"]

      assert %{"result" => %{"id" => ^task_id}} = rpc(ctx, "bob", "tasks/get", %{"id" => task_id})

      assert_task_not_found(
        rpc(ctx, "alice", "tasks/get", %{"id" => task_id}),
        "alice on bob's forged-metadata task"
      )

      # bob cannot smuggle a continuation of alice's live task through forged
      # metadata either: ownership comes from the verified bearer identity.
      %{"id" => alice_id} = create_task(ctx, "alice")

      assert_task_not_found(
        rpc(ctx, "bob", "message/send", %{
          "message" => message(%{"taskId" => alice_id}),
          "metadata" => forged["metadata"]
        }),
        "bob's forged continuation of alice's task"
      )

      # alice's task is unharmed and still hers.
      assert %{"result" => %{"id" => ^alice_id}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => alice_id})
    end
  end

  describe "(d) nothing published ever carries internal metadata" do
    @tag :serial
    test "tasks, SSE frames and webhook bodies are scrubbed of a2a.auth, owner and stream refs",
         ctx do
      secret = "raw-credential-of-alice"

      # Alice creates + completes a task with an inline push config, so the
      # same task crosses every publication surface: JSON-RPC responses,
      # SSE frames, the event backlog and a real webhook delivery.
      send_resp =
        call(ctx, "alice", "message/send", %{
          "message" => skill_message("converse", %{"say" => "publish"}, nil),
          "configuration" => %{"pushNotificationConfig" => %{"url" => ctx.hook}}
        })

      assert send_resp.status == 200
      body = send_resp.resp_body
      refute body =~ secret, "message/send echoed the raw credential"
      decoded = Jason.decode!(body)
      assert_no_internal_keys(decoded, "$message_send")
      %{"result" => %{"task" => %{"id" => task_id}}} = decoded

      # Real signed webhook delivery to the real loopback receiver.
      assert_receive {:webhook, hook_body}, 5_000
      assert hook_body =~ task_id
      refute hook_body =~ secret
      refute hook_body =~ "a2a.auth"
      assert_no_internal_keys(Jason.decode!(hook_body), "$webhook")

      # tasks/get and tasks/list.
      get = call(ctx, "alice", "tasks/get", %{"id" => task_id})
      refute get.resp_body =~ secret
      assert_no_internal_keys(Jason.decode!(get.resp_body), "$tasks_get")

      list = call(ctx, "alice", "tasks/list", %{})
      refute list.resp_body =~ secret
      assert_no_internal_keys(Jason.decode!(list.resp_body), "$tasks_list")

      # tasks/resubscribe SSE frames (snapshot + backlog replay).
      resub = call(ctx, "alice", "tasks/resubscribe", %{"id" => task_id})
      refute resub.resp_body =~ secret
      assert resub.resp_body =~ task_id
      assert_no_internal_keys_sse(resub.resp_body, "$resubscribe")

      # message/stream SSE frames: a real streaming skill (a seeded read
      # driven through the real Ash.stream!/2), so the frames are the task
      # snapshot, one ArtifactUpdate per record and the final StatusUpdate.
      Enum.each(1..3, fn i ->
        Ash.Seed.seed!(AshA2AV1OwnerScopeTest.Converse, %{label: "w12-chunk-#{i}"})
      end)

      # The read skill streams only when the request data carries
      # `stream: true` (dispatcher pop_stream_flag/1) — send it for real so
      # the court exercises actual chunk streaming, not (historically) the
      # unredacted error leak that used to carry the chunk texts.
      stream =
        call(
          ctx,
          "alice",
          "message/stream",
          %{"message" => skill_message("stream_chunks", %{"stream" => true})}
        )

      refute stream.resp_body =~ secret
      assert stream.resp_body =~ "w12-chunk-3"
      assert_no_internal_keys_sse(stream.resp_body, "$message_stream")

      # The in-memory event backlog a late resubscriber would replay.
      backlog = AshA2A.A2ATransport.TaskEvents.backlog(ctx.transport, task_id)
      refute inspect(backlog) =~ secret

      Enum.each(backlog, fn {_seq, _kind, payload, _final?} ->
        assert_no_internal_keys(payload, "$backlog")
      end)
    end
  end

  # SSE bodies are frame-delimited (not one JSON document); assert every
  # decodable JSON line in the stream, and that no internal key appears as a
  # raw substring anywhere in the raw frame text.
  defp assert_no_internal_keys_sse(body, path) do
    # "stream" is scoped to the decoded-walk check (a user data part may
    # carry a "stream" key); the two credential keys are substring-checked.
    Enum.each(@internal_keys, fn key ->
      refute body =~ ~s("#{key}"), "#{path}: raw internal key #{inspect(key)} in SSE text"
    end)

    body
    |> String.split("\n")
    |> Enum.each(fn line ->
      line = String.trim_trailing(line, "\r")

      if line != "" and not String.starts_with?(line, ["data: ", "event:", "id:", ":"]) do
        # Non-SSE-field lines in these streams are JSON payloads; decode
        # defensively (keepalives/comments are skipped by the guard above).
        case Jason.decode(line) do
          {:ok, json} -> assert_no_internal_keys(json, path)
          {:error, _} -> :ok
        end
      else
        case String.split(line, "data: ", parts: 2) do
          [_, payload] ->
            case Jason.decode(payload) do
              {:ok, json} -> assert_no_internal_keys(json, path)
              {:error, _} -> :ok
            end

          _ ->
            :ok
        end
      end
    end)
  end

  describe "(e) task ids on the wire are 128-bit CSPRNG" do
    test "format, entropy width and uniqueness over 20 creates across principals", ctx do
      ids =
        for i <- 1..20 do
          user = if rem(i, 2) == 0, do: "alice", else: "bob"
          %{"id" => id} = create_task(ctx, user)
          id
        end

      assert length(Enum.uniq(ids)) == 20, "task id collision over 20 creates"

      Enum.each(ids, fn id ->
        assert Regex.match?(~r/^tsk-[A-Za-z0-9_-]{22}$/, id), "malformed task id: #{id}"

        assert {:ok, <<_::128>>} =
                 Base.url_decode64(binary_part(id, 4, 22), padding: false),
               "task id suffix is not 128 random bits: #{id}"
      end)
    end
  end

  describe "(f) anonymous callers fail closed" do
    test "no auth on a require_authenticated_caller agent: refused, cannot list", ctx do
      %{"id" => task_id} = create_task(ctx, "alice")

      # Anonymous reads and continuations are the same -32001 as anyone else
      # would get for a genuinely unknown task.
      assert_task_not_found(
        rpc(ctx, :anonymous, "tasks/get", %{"id" => task_id}),
        "anonymous tasks/get"
      )

      # Anonymous message/send is refused by the agent's authentication gate:
      # the task fails with the typed unauthenticated refusal, never runs.
      refuse = rpc(ctx, :anonymous, "message/send", %{"message" => message()})

      assert %{
               "result" => %{
                 "task" => %{
                   "status" => %{
                     "state" => "TASK_STATE_FAILED",
                     "message" => %{"parts" => parts}
                   }
                 }
               }
             } = refuse

      assert parts |> Enum.map(& &1["text"]) |> Enum.join(" ") =~ "unauthenticated"

      # The refusal created no task and revealed nothing: alice's task is
      # untouched and still hers alone.
      assert %{"result" => %{"id" => ^task_id}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => task_id})
    end
  end

  # The wrapper transport's own `tasks/list` delegates to the vendored plug's
  # list, which has no principal concept without an `:authorize_task`
  # callback; the owner-scoped list surface in this suite is
  # `AshA2A.Transport.Plug` (the documented owner-scoped transport), whose
  # `tasks/get`/`tasks/list` go through `AshA2A.Transport.Runtime`'s
  # `get_task_for/3` / `list_tasks_for/3` -- the fail-closed list gate.
  describe "(g) owner-scoped reads: list is principal-scoped and anonymous never lists" do
    test "each principal lists only her own tasks; anonymous enumerates nothing", ctx do
      alice1 = create_task(ctx, "alice")
      alice2 = create_task(ctx, "alice")
      bob1 = create_task(ctx, "bob")

      assert %{"result" => %{"tasks" => alice_list}} = scoped_rpc(ctx, "alice", "tasks/list", %{})

      assert Enum.sort(Enum.map(alice_list, & &1["id"])) ==
               Enum.sort([alice1["id"], alice2["id"]])

      assert %{"result" => %{"tasks" => bob_list}} = scoped_rpc(ctx, "bob", "tasks/list", %{})
      assert Enum.map(bob_list, & &1["id"]) == [bob1["id"]]

      # The anonymous principal (no verified identity in conn.private) lists
      # nothing at all: fail closed, no enumeration, even though tasks exist.
      assert %{"result" => %{"tasks" => []}} = scoped_rpc(ctx, :anonymous, "tasks/list", %{})

      # Anonymous reads are the usual indistinguishable -32001.
      assert_task_not_found(
        scoped_rpc(ctx, :anonymous, "tasks/get", %{"id" => alice1["id"]}),
        "anonymous tasks/get on the scoped surface"
      )

      # And the gate is a refusal, not an error: alice's reads still work.
      assert %{"result" => %{"id" => id}} =
               scoped_rpc(ctx, "alice", "tasks/get", %{"id" => alice1["id"]})

      assert id == alice1["id"]

      # Every listed task on the scoped surface is scrubbed too.
      Enum.each(alice_list ++ bob_list, fn task ->
        assert_no_internal_keys(task, "$scoped_list")
      end)
    end
  end

  describe "(h) the SSE error path is redacted (lane X2)" do
    @tag :serial
    test "message/stream on a non-streaming skill answers a redacted -32603 frame, not the task inspect",
         ctx do
      secret = "raw-credential-of-alice"

      # Real rows the non-streaming read folds into the task's artifacts: if
      # the redaction at a2a_transport/sse.ex (the `{:error, reason}` branch
      # of stream_message/6) is ever reverted to a bare `inspect(reason)`,
      # these strings went onto the wire verbatim.
      Enum.each(1..3, fn i ->
        Ash.Seed.seed!(AshA2AV1OwnerScopeTest.Converse, %{label: "w12-redact-#{i}"})
      end)

      # A real message/stream against a skill that does NOT stream (the read
      # skill without the dispatcher's `stream: true` data flag): Protocol
      # .stream/3 answers {:error, {:not_streaming, task}} and the SSE
      # handler answers the JSON-RPC error frame, not event frames.
      conn = call(ctx, "alice", "message/stream", %{"message" => skill_message("stream_chunks")})
      body = conn.resp_body
      decoded = Jason.decode!(body)

      # Anti-vacuity: this body IS the error frame. The code pin proves the
      # error path was really taken -- marker refutations on a success frame
      # would pass vacuously (the silent pass X2 proved).
      assert %{"error" => %{"code" => -32_603}} = decoded

      # The task struct inspect never reaches the wire.
      refute body =~ "%AshA2A.Protocol.Task{"

      # No credential material, no owner key, no seeded row content.
      refute body =~ secret
      refute body =~ "a2a.auth"
      refute body =~ "ash_a2a.owner"
      refute body =~ "w12-redact-"

      assert_no_internal_keys(decoded, "$stream_error")

      # Teeth on real state: the stored task the error tuple carries DOES
      # carry the leak markers internally, so the refutations above are
      # load-bearing -- reverting the redaction re-leaks exactly these.
      assert %{"result" => %{"tasks" => [task | _]}} =
               scoped_rpc(ctx, "alice", "tasks/list", %{})

      assert {:ok, internal} = GenServer.call(ctx.agent, {:get_task, task["id"]})

      # The stored task is exactly the struct the error tuple carries: its
      # inspect embeds the struct header, the owner key and the completed
      # read's row artifacts, so the refutations above are load-bearing --
      # reverting the sse.ex redaction re-leaks exactly these.
      leak_vector = inspect({:not_streaming, internal})
      assert leak_vector =~ "%AshA2A.Protocol.Task{", "leak vector lost the task struct header"
      assert leak_vector =~ "ash_a2a.owner", "leak vector lost the owner-key marker"
      assert leak_vector =~ "w12-redact-1", "internal task no longer carries the row content"
    end
  end

  # Real owner-scoped transport plug mounted after the same real bearer auth
  # middleware, over the same real agent.
  defp scoped_rpc(ctx, user, method, params) do
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
      |> then(&if(is_binary(user),
        do: Plug.Conn.put_req_header(&1, "authorization", "Bearer " <> user),
        else: &1
      ))
      |> then(&if(is_binary(user), do: AshA2A.Protocol.Plug.Auth.call(&1, ctx.auth), else: &1))

    AshA2A.Transport.Plug.call(conn, ctx.scoped_plug).resp_body |> Jason.decode!()
  end
end
