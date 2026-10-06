# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim.Push.Session do
  @moduledoc false
  # Real ETS-backed Ash resource modelling a conference session an attendee
  # manages: `message/send` without structured data pauses the real task at
  # TASK_STATE_INPUT_REQUIRED (a continuable, live session task); the
  # follow-up carrying `{"new_time": ...}` "reschedules" it terminal
  # TASK_STATE_COMPLETED with the new slot in the real output artifact.
  use Ash.Resource,
    domain: ConferenceSim.Push.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :manage, :map do
      argument(:new_time, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{rescheduled_to: input.arguments.new_time}}
      end)
    end
  end

  a2a do
    skill(:manage, :manage, consequence: :observe)
  end
end

defmodule ConferenceSim.Push.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(ConferenceSim.Push.Session)
  end
end

defmodule ConferenceSim.Push.Agent do
  @moduledoc false
  # Real `AshA2A.Agent` GenServer (transport runtime: owner-keyed tasks,
  # CSPRNG ids) serving the session resource.
  use AshA2A.Agent,
    resource_or_domain: ConferenceSim.Push.Domain,
    name: "conference_sim_push_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule ConferenceSim.Push.Receiver do
  @moduledoc false
  # Real Bandit webhook receiver: forwards (headers, body) to the test pid
  # tagged with its attendee slot and answers 200.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test, attendee: attendee}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:push_delivered, attendee, conn.req_headers, body})
    send_resp(conn, 200, "")
  end
end

defmodule ConferenceSim.PushCourt do
  @moduledoc """
  Conference-sim lane EV6 court: session-change alerts as A2A push
  notifications -- the full push lifecycle (G2's surface) under real event
  conditions.

  Five attendees each own a real session task on a real `AshA2A.Agent`
  transport runtime and subscribe a real `TaskPushNotificationConfig` whose
  receiver is a real, per-attendee Bandit endpoint on an OS-assigned
  ephemeral loopback port. Zero mocks: receivers are real HTTP servers,
  delivery is the real `AshA2A.A2ATransport.PushDelivery` worker, attempts
  are read from the real `AshA2A.A2ATransport.TaskEvents` attempt log.

  ## Courts

    * **Fan-out + new state + auth** -- rescheduling every session
      (continuation `message/send` with `{"new_time": ...}`) lands exactly
      one notification on every receiver, whose wrapped task carries the new
      `TASK_STATE_COMPLETED` state and the rescheduled slot, the config's
      `token` as `X-A2A-Notification-Token`, the config's
      `authentication.credentials` as the `Authorization: Bearer` header, and
      an HMAC signature that verifies against the real signing secret on the
      receiver side.
    * **Retry with backoff, and honest exhaustion** -- a receiver that is
      genuinely down (its Bandit listener killed) draws repeated failed
      delivery attempts with exponential backoff and succeeds once it comes
      back mid-backoff; a receiver that never comes back draws exactly
      `max_attempts` failed attempts and no success -- exhausted honestly.
    * **Mid-session config deletion** -- after a delivered event, deleting
      the config stops further deliveries to that attendee while a still-
      configured attendee keeps receiving; `get`/`list` reflect the removal.
    * **IDOR** -- an attendee naming another attendee's session task on any
      push verb is answered exactly like a missing task (`-32001`
      `TASK_NOT_FOUND`), byte-identical to the unknown-task answer.
    * **Typed SSRF refusal at config-set** -- an `http://` receiver URL under
      the transport's safe defaults (https-only) is refused with the typed
      `refused_webhook_scheme` detail and nothing is stored.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.{PushConfigStore, PushDelivery, TaskEvents}
  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}
  @secret "conference-sim-ev6-push-signing-secret"
  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @max_attempts 5
  @backoff_ms 25

  # Real verify callback: the bearer token names the attendee.
  def verify("bearer", token, _conn), do: {:ok, %{sub: token}}

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"conference_sim_push_agent_#{uniq}"
    transport = :"a2a_transport_conf_sim_push_#{uniq}"

    start_supervised!({ConferenceSim.Push.Agent, name: agent})

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport,
       push: [
         allow_http: true,
         allow_cidrs: ["127.0.0.1/32"],
         signing_secret: @secret,
         max_attempts: @max_attempts,
         base_backoff_ms: @backoff_ms,
         max_backoff_ms: 200
       ]}
    )

    # A second transport under the SAFE push defaults (https-only, no
    # loopback allowlist) -- the SSRF court's admitted-policy baseline.
    safe_transport = :"a2a_transport_conf_sim_push_safe_#{uniq}"

    start_supervised!(
      {AshA2A.A2ATransport, name: safe_transport, push: [signing_secret: @secret]}
    )

    %{
      agent: agent,
      transport: transport,
      auth: AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3),
      plug:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true
        ),
      safe_plug:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: safe_transport,
          push_notifications: true
        )
    }
  end

  # -- wire helpers -------------------------------------------------------------

  defp call(ctx, plug, user, method, params) do
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
      |> TransportPlug.call(plug)

    refute conn.halted, "auth middleware halted for #{user}"
    conn.resp_body |> Jason.decode!()
  end

  defp rpc(ctx, user, method, params), do: call(ctx, ctx.plug, user, method, params)

  defp skill_message(data, task_id) do
    parts = if data, do: [Part.Data.new(data)], else: [Part.Text.new("go")]

    msg =
      struct(Message.new_user(parts),
        task_id: task_id,
        metadata: %{"skill" => "manage"}
      )

    {:ok, encoded} = JSON.encode(msg)
    encoded
  end

  # Creates a fresh live (TASK_STATE_INPUT_REQUIRED) session task owned by
  # `user`.
  defp create_task(ctx, user) do
    resp = rpc(ctx, user, "message/send", %{"message" => skill_message(nil, nil)})

    case resp do
      %{"result" => %{"task" => %{"id" => id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}} ->
        id

      other ->
        flunk("create_task did not pause at INPUT_REQUIRED: #{inspect(other)}")
    end
  end

  defp set_config(ctx, user, task_id, config),
    do:
      rpc(ctx, user, "tasks/pushNotificationConfig/set", %{
        "taskId" => task_id,
        "pushNotificationConfig" => config
      })

  # The reschedule event: a real continuation `message/send` carrying the new
  # slot; the task lands terminal TASK_STATE_COMPLETED.
  defp reschedule(ctx, user, task_id, new_time) do
    assert %{"result" => %{"task" => %{"status" => %{"state" => state}}}} =
             rpc(ctx, user, "message/send", %{
               "message" => skill_message(%{"new_time" => new_time}, task_id)
             })

    state
  end

  # A non-terminal session event: a continuation that leaves the task live at
  # TASK_STATE_INPUT_REQUIRED (still continuable), publishing a status-bearing
  # event -- the "session held/updated" transition used before and after a
  # config deletion.
  defp nudge(ctx, user, task_id) do
    assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}} =
             rpc(ctx, user, "message/send", %{
               "message" => skill_message(nil, task_id)
             })
  end

  defp attempts(transport, task_id, n, tries \\ 150)

  defp attempts(transport, task_id, n, tries) do
    found = TaskEvents.attempts(transport, task_id)

    cond do
      length(found) >= n -> found
      tries == 0 -> flunk("expected >=#{n} attempts, got #{inspect(found)}")
      true ->
        Process.sleep(20)
        attempts(transport, task_id, n, tries - 1)
    end
  end

  defp start_receiver(attendee, port \\ 0) do
    EphemeralHttp.start!({ConferenceSim.Push.Receiver, %{test: self(), attendee: attendee}},
      port: port
    )
  end

  defp kill_receiver(hook) do
    # Take the real listener down without the link propagating to the test
    # process (EphemeralHttp links Bandit to its caller).
    Process.unlink(hook.pid)
    Process.exit(hook.pid, :kill)
    Process.sleep(10)
    :ok
  end

  defp down_receiver do
    # A genuinely dead endpoint: a real listener that is then killed, so the
    # port was owned and is now provably closed.
    hook = start_receiver(:never)
    kill_receiver(hook)
    hook
  end

  defp config_for(hook_url, id) do
    %{
      "id" => id,
      "url" => hook_url,
      "token" => "tok-" <> id,
      "authentication" => %{"schemes" => ["Bearer"], "credentials" => "s3cret-" <> id}
    }
  end

  # -- court 1: fan-out, new state, auth, signature -------------------------------

  test "rescheduling 5 sessions notifies all 5 receivers with the new state, token, bearer header and a verifying signature", %{
    transport: transport
  } = ctx do
    attendees = [:alice, :bob, :carol, :dave, :erin]

    hooks = Map.new(attendees, fn a -> {a, start_receiver(a)} end)

    sessions =
      Map.new(attendees, fn a ->
        task_id = create_task(ctx, "#{a}")
        url = hooks[a].base_url <> "/hook"

        assert %{"result" => %{"pushNotificationConfig" => stored}} =
                 set_config(ctx, "#{a}", task_id, config_for(url, "cfg-#{a}"))

        assert stored["url"] == url
        # Write-only credentials are never echoed...
        refute get_in(stored, ["authentication", "credentials"])

        # ...but really live in the store for delivery.
        {:ok, record} =
          PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task_id, "cfg-#{a}")

        assert record.authentication["credentials"] == "s3cret-cfg-#{a}"
        {a, task_id}
      end)

    # The session-change event: every session is rescheduled.
    for {a, i} <- Enum.with_index(attendees) do
      new_time = "2026-10-06T#{10 + i}:00:00Z"
      assert reschedule(ctx, "#{a}", sessions[a], new_time) == "TASK_STATE_COMPLETED"
    end

    # Every receiver got exactly the update for its own session.
    for {a, i} <- Enum.with_index(attendees) do
      assert_receive {:push_delivered, ^a, headers, body}, 5_000
      headers = Map.new(headers)
      decoded = Jason.decode!(body)

      # The task's NEW state after the reschedule...
      assert %{
               "task" => %{
                 "id" => task_id,
                 "status" => %{"state" => "TASK_STATE_COMPLETED"}
               }
             } = decoded

      assert task_id == sessions[a]

      # ...and the rescheduled slot itself.
      assert body =~ "2026-10-06T#{10 + i}:00:00Z"

      # Token + bearer auth from the stored config.
      assert headers["x-a2a-notification-token"] == "tok-cfg-#{a}"
      assert headers["authorization"] == "Bearer s3cret-cfg-#{a}"

      # Receiver-side HMAC verification against the real signing secret.
      assert :ok =
               PushDelivery.verify_signature(
                 @secret,
                 headers["x-a2a-timestamp"],
                 headers["x-a2a-signature"],
                 body
               )
    end

    # No spurious extra deliveries.
    refute_receive {:push_delivered, _, _, _}, 250
  end

  # -- court 2: retry with backoff, and honest exhaustion --------------------------

  test "a down receiver is retried with backoff and succeeds when it comes back", %{
    transport: transport
  } = ctx do
    hook = start_receiver(:retry)
    task_id = create_task(ctx, "retry")
    set_config(ctx, "retry", task_id, config_for(hook.base_url <> "/hook", "cfg-retry"))

    # The receiver goes genuinely down before the session change...
    kill_receiver(hook)

    assert reschedule(ctx, "retry", task_id, "2026-10-07T09:00:00Z") == "TASK_STATE_COMPLETED"

    # ...draws at least one real failed attempt (connection refused)...
    first = attempts(transport, task_id, 1, 300)
    assert [%{outcome: {:transport_error, _}} | _] = first

    # ...and because the receiver comes back mid-backoff, a later attempt
    # lands. Restart on the SAME port the config pins.
    {:ok, _pid} =
      Bandit.start_link(
        plug: {ConferenceSim.Push.Receiver, %{test: self(), attendee: :retry}},
        port: hook.port,
        ip: {127, 0, 0, 1}
      )

    all =
      Enum.reduce_while(1..400, first, fn _, _acc ->
        found = TaskEvents.attempts(transport, task_id)

        if Enum.any?(found, &match?(%{outcome: {:ok, 200}}, &1)) do
          {:halt, found}
        else
          Process.sleep(10)
          {:cont, found}
        end
      end)

    assert ok = Enum.find(all, &match?(%{outcome: {:ok, 200}}, &1)),
           "no successful attempt after restart: #{inspect(all)}"

    assert ok.attempt > 1, "expected a retry (not the first attempt) to succeed"
    assert length(all) <= @max_attempts

    assert_receive {:push_delivered, :retry, _headers, body}, 5_000
    assert %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = Jason.decode!(body)
  end

  test "a receiver that never comes back is exhausted honestly at max_attempts", %{
    transport: transport
  } = ctx do
    hook = down_receiver()
    task_id = create_task(ctx, "gone")
    set_config(ctx, "gone", task_id, config_for(hook.base_url <> "/hook", "cfg-gone"))

    assert reschedule(ctx, "gone", task_id, "2026-10-07T11:00:00Z") == "TASK_STATE_COMPLETED"

    all = attempts(transport, task_id, @max_attempts)

    assert length(all) == @max_attempts
    assert Enum.all?(all, &match?(%{outcome: {:transport_error, _}}, &1))
    # Backoff really backs off: strictly increasing sleeps between attempts.
    gaps =
      Enum.map(1..(length(all) - 1), &PushDelivery.backoff(&1, base_backoff_ms: @backoff_ms, max_backoff_ms: 200))

    assert gaps == Enum.sort(gaps)

    refute_receive {:push_delivered, :gone, _, _}, 250
  end

  # -- court 3: mid-session config deletion ---------------------------------------

  test "deleting a config mid-session stops that attendee's deliveries; others unaffected; get/list reflect it", %{
    transport: transport
  } = ctx do
    hook_mia = start_receiver(:mia)
    hook_live = start_receiver(:live)

    task_mia = create_task(ctx, "mia")
    task_live = create_task(ctx, "live")

    set_config(ctx, "mia", task_mia, config_for(hook_mia.base_url <> "/hook", "cfg-mia"))
    set_config(ctx, "live", task_live, config_for(hook_live.base_url <> "/hook", "cfg-live"))

    # Event 1: both still-configured attendees are notified. Mia's event is a
    # live (non-terminal) session update; live's is a full reschedule.
    nudge(ctx, "mia", task_mia)

    assert reschedule(ctx, "live", task_live, "2026-10-07T13:00:00Z") == "TASK_STATE_COMPLETED"

    assert_receive {:push_delivered, :mia, _, body}, 5_000

    assert %{"task" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
             Jason.decode!(body)

    assert_receive {:push_delivered, :live, _, _}, 5_000

    # Mia deletes her config mid-session.
    assert %{"result" => nil} =
             rpc(ctx, "mia", "tasks/pushNotificationConfig/delete", %{
               "id" => task_mia,
               "pushNotificationConfigId" => "cfg-mia"
             })

    # get/list reflect the removal.
    assert %{"result" => []} =
             rpc(ctx, "mia", "tasks/pushNotificationConfig/list", %{"id" => task_mia})

    assert %{"error" => %{"code" => -32_602, "data" => [%{"reason" => "INVALID_PARAMS"}]}} =
             rpc(ctx, "mia", "tasks/pushNotificationConfig/get", %{
               "id" => task_mia,
               "pushNotificationConfigId" => "cfg-mia"
             })

    # Event 2: a second, still-configured attendee's session changes in the
    # same window -- the pipeline is alive while mia is dark.
    hook_live2 = start_receiver(:live2)
    task_live2 = create_task(ctx, "live2")
    set_config(ctx, "live2", task_live2, config_for(hook_live2.base_url <> "/hook", "cfg-live2"))

    assert reschedule(ctx, "live2", task_live2, "2026-10-07T14:00:00Z") == "TASK_STATE_COMPLETED"
    assert_receive {:push_delivered, :live2, _, _}, 5_000

    # Mia's task changes state again after her delete: no further delivery.
    mia_attempts_before = TaskEvents.attempts(transport, task_mia)
    nudge(ctx, "mia", task_mia)

    refute_receive {:push_delivered, :mia, _, _}, 400
    Process.sleep(100)
    assert TaskEvents.attempts(transport, task_mia) == mia_attempts_before,
           "a delivery attempt was started for a deleted config"
  end

  # -- court 4: IDOR ---------------------------------------------------------------

  test "an attendee cannot read or set push configs on another attendee's session (IDOR)", ctx do
    hook = start_receiver(:alice)
    task_alice = create_task(ctx, "alice")
    set_config(ctx, "alice", task_alice, config_for(hook.base_url <> "/hook", "cfg-a"))

    for {method, params} <- [
          {"tasks/pushNotificationConfig/set",
           %{
             "taskId" => task_alice,
             "pushNotificationConfig" => config_for("https://attacker.test/hook", "cfg-b")
           }},
          {"tasks/pushNotificationConfig/get", %{"id" => task_alice}},
          {"tasks/pushNotificationConfig/list", %{"id" => task_alice}},
          {"tasks/pushNotificationConfig/delete",
           %{"id" => task_alice, "pushNotificationConfigId" => "cfg-a"}}
        ] do
      resp = rpc(ctx, "bob", method, params)

      assert %{"error" => %{"code" => -32_001, "data" => [%{"reason" => "TASK_NOT_FOUND"}]}} =
               resp,
             "#{method} as bob was not owner-scoped: #{inspect(resp)}"
    end

    # Indistinguishable from a genuinely unknown task, byte for byte.
    foreign = rpc(ctx, "bob", "tasks/pushNotificationConfig/get", %{"id" => task_alice})
    unknown = rpc(ctx, "bob", "tasks/pushNotificationConfig/get", %{"id" => "tsk-nope-000"})
    assert foreign["error"] == unknown["error"]

    # The owner still sees her config; nothing bob did disturbed it.
    assert %{"result" => [%{"pushNotificationConfig" => %{"id" => "cfg-a"}}]} =
             rpc(ctx, "alice", "tasks/pushNotificationConfig/list", %{"id" => task_alice})
  end

  # -- court 5: typed SSRF refusal under safe defaults ------------------------------

  test "an http:// receiver URL under safe defaults is refused typed at config-set", ctx do
    task_id = create_task(ctx, "carol")

    for url <- ["http://example.com/hook", "http://127.0.0.1:9/hook"] do
      resp =
        call(ctx, ctx.safe_plug, "carol", "tasks/pushNotificationConfig/set", %{
          "taskId" => task_id,
          "pushNotificationConfig" => config_for(url, "cfg-safe")
        })

      assert %{
               "error" => %{
                 "code" => -32_602,
                 "data" => [
                   %{
                     "@type" => @error_info_type,
                     "reason" => "INVALID_PARAMS",
                     "metadata" => %{"detail" => detail}
                   }
                 ]
               }
             } = resp,
             url

      assert detail =~ "refused_webhook_scheme", url
    end

    # Nothing was stored (the safe transport's own store).
    assert %{"result" => []} =
             call(ctx, ctx.safe_plug, "carol", "tasks/pushNotificationConfig/list", %{
               "id" => task_id
             })
  end
end
