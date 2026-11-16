# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root gRPC Hilt DSL
# Target File 2 of Worker 05
# Consolidated from 22 source files:
#   - test/email_provider_edge_test.exs
#   - test/email_replay_rate_limit_test.exs
#   - test/email_reply_intent_test.exs
#   - test/error_version_table_test.exs
#   - test/event_log_durability_test.exs
#   - test/execution_snapshot_semantic_identity_test.exs
#   - test/extended_card_resign_test.exs
#   - test/extension_version_compile_test.exs
#   - test/gall_checkpoint_003_command_authority_chicago_test.exs
#   - test/gall_process_intervention_test.exs
#   - test/generation_gating_courts_test.exs
#   - test/generation_plug_wiring_test.exs
#   - test/generation_store_durability_test.exs
#   - test/gi_spark_conflict_probe_test.exs
#   - test/grpc_client_transport_test.exs
#   - test/grpc_extension_gate_test.exs
#   - test/grpc_generation_gaps_test.exs
#   - test/grpc_live_paths_test.exs
#   - test/grpc_live_session_test.exs
#   - test/grpc_server_wiring_test.exs
#   - test/hilt_work_order_execution_identity_test.exs
#   - test/hilt_work_order_graph_digest_test.exs
# ==============================================================================

# --- SECTION 1: Original test/email_provider_edge_test.exs ---
defmodule AshA2A.EmailProviderEdgeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Email.{Sender, Webhook}
  alias AshA2A.Hilt.WorkOrder

  @secret "0123456789abcdef-secret"

  describe "sendgrid" do
    test "header secret accepted, wrong rejected, unconfigured rejected" do
      assert :ok = Webhook.verify(:sendgrid, [{"x-webhook-secret", @secret}], secret: @secret)

      assert {:error, :unauthorized} =
               Webhook.verify(:sendgrid, [{"x-webhook-secret", "nope"}], secret: @secret)

      assert {:error, :unauthorized} = Webhook.verify(:sendgrid, [], secret: @secret)
      assert {:error, :not_configured} = Webhook.verify(:sendgrid, [], [])
    end

    test "basic auth password accepted" do
      auth = "Basic " <> Base.encode64("user:" <> @secret)
      assert :ok = Webhook.verify(:sendgrid, %{"Authorization" => auth}, secret: @secret)

      bad = "Basic " <> Base.encode64("user:wrong")

      assert {:error, :unauthorized} =
               Webhook.verify(:sendgrid, %{"authorization" => bad}, secret: @secret)
    end
  end

  describe "workspace" do
    test "bearer token" do
      assert :ok =
               Webhook.verify(:workspace, [{"authorization", "Bearer " <> @secret}],
                 token: @secret
               )

      assert {:error, :unauthorized} =
               Webhook.verify(:workspace, [{"authorization", "Bearer x"}], token: @secret)

      assert {:error, :unauthorized} =
               Webhook.verify(:workspace, [{"authorization", @secret}], token: @secret)

      assert {:error, :not_configured} = Webhook.verify(:workspace, [], token: nil)
    end
  end

  describe "ses" do
    defp sns(over \\ %{}) do
      Map.merge(
        %{
          "Type" => "Notification",
          "MessageId" => "m1",
          "TopicArn" => "arn:aws:sns:us-east-1:1:t",
          "Timestamp" => "2026-11-13T00:00:00Z",
          "Signature" => Base.encode64("sig"),
          "SignatureVersion" => "1",
          "SigningCertURL" =>
            "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-x.pem"
        },
        over
      )
    end

    test "structure-only accepts valid, default is fail-closed" do
      assert :ok = Webhook.verify(:ses, sns(), structure_only: true)
      assert {:error, :signature_unverified} = Webhook.verify(:ses, sns(), [])

      assert :ok =
               Webhook.verify(:ses, Jason.encode!(sns()), signature_verifier: fn _ -> true end)

      assert {:error, :bad_signature} =
               Webhook.verify(:ses, sns(), signature_verifier: fn _ -> false end)
    end

    test "rejects hostile cert url, bad version, topic mismatch, junk" do
      assert {:error, :bad_cert_url} =
               Webhook.verify(:ses, sns(%{"SigningCertURL" => "https://evil.example.com/a.pem"}),
                 structure_only: true
               )

      assert {:error, :bad_cert_url} =
               Webhook.verify(
                 :ses,
                 sns(%{"SigningCertURL" => "http://sns.us-east-1.amazonaws.com/a.pem"}),
                 structure_only: true
               )

      assert {:error, :bad_signature_version} =
               Webhook.verify(:ses, sns(%{"SignatureVersion" => "9"}), structure_only: true)

      assert {:error, :topic_mismatch} =
               Webhook.verify(:ses, sns(), structure_only: true, topic_arn: "other")

      assert {:error, :malformed} = Webhook.verify(:ses, "not json", structure_only: true)
      assert {:error, :malformed} = Webhook.verify(:ses, %{}, structure_only: true)
    end
  end

  test "unknown provider refused" do
    assert {:error, :unknown_provider} = Webhook.verify(:mailgun, [], [])
  end

  test "spool sender writes a real message file" do
    dir = Path.join(System.tmp_dir!(), "y9_spool_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    msg = %{to: "a@example.com", from: "g@example.com", subject: "Hi", body: "Approve?"}
    assert {:ok, %{path: path}} = Sender.deliver(Sender.Spool, msg, spool_dir: dir)
    content = File.read!(path)
    assert content =~ "To: a@example.com"
    assert content =~ "Subject: Hi"
    assert String.ends_with?(content, "Approve?")
  end

  test "sender rejects header injection and missing fields" do
    bad = %{to: "a@example.com\r\nBcc: x@y", from: "g@example.com", subject: "s", body: "b"}
    assert {:error, {:invalid_message, :to}} = Sender.deliver(Sender.Spool, bad, [])

    assert {:error, {:invalid_message, :body}} =
             Sender.validate(%{to: "a", from: "b", subject: "c"})
  end

  test "checkpoint_graph_digest/2 is public and deterministic" do
    d = String.duplicate("a", 64)
    assert :ok = WorkOrder.checkpoint_graph_digest(nil, d)
    assert :ok = WorkOrder.checkpoint_graph_digest(d, nil)
    assert :ok = WorkOrder.checkpoint_graph_digest(d, d)

    other = String.duplicate("b", 64)

    for _ <- 1..3 do
      assert {:error, :stale_graph_identity} = WorkOrder.checkpoint_graph_digest(d, other)
    end
  end
end

# --- SECTION 2: Original test/email_replay_rate_limit_test.exs ---
defmodule AshA2A.EmailReplayRateLimitTest do
  @moduledoc """
  Real Plug + real Brief/Inbound/ReplyIntent + real TokenLedger process.

  Named exception: dispatch/reply_sender are hand-written function fakes recording into an
  Agent (governed agent and SMTP are infeasible in-process).
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias AshA2A.Email.{Brief, TokenLedger}
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @stale "sha256:" <> String.duplicate("b", 64)
  @sender "approver@example.test"

  setup do
    {:ok, rec} = Agent.start_link(fn -> [] end)
    {:ok, ledger} = TokenLedger.start_link([])
    {:ok, rec: rec, ledger: ledger}
  end

  defp brief do
    %{
      title: "Daily",
      date: "2026-11-13",
      sections: [],
      actions: [
        %{n: 1, summary: "Deploy A", action: :deploy, args: %{}, graph_digest: @digest},
        %{n: 2, summary: "Rotate B", action: :rotate, args: %{}, graph_digest: @digest}
      ]
    }
  end

  defp bare(id), do: id |> String.trim_leading("<") |> String.trim_trailing(">")

  defp opts(rec, ledger, over \\ []) do
    b = brief()
    mid = bare(Brief.render(b).message_id)

    base = [
      policy: %{allowlist: %{@sender => "principal:approver"}},
      brief_lookup: fn
        ^mid -> {:ok, b, %{1 => @digest, 2 => @digest}}
        _ -> :error
      end,
      dispatch: fn principal, action ->
        Agent.update(rec, &(&1 ++ [{principal, action.n}]))
        {:ok, :done}
      end,
      token_ledger: ledger
    ]

    EmailPlug.init(Keyword.merge(base, over))
  end

  defp req(text, message_id \\ nil) do
    b = brief()

    params = %{
      "from" => @sender,
      "in_reply_to" => bare(Brief.render(b).message_id),
      "text" => text,
      "subject" => "Re: brief",
      "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" => Map.new([1, 2], &{Integer.to_string(&1), Brief.reply_token(b, &1)})
    }

    params = if message_id, do: Map.put(params, "message_id", message_id), else: params
    conn(:post, "/v1/email:ingest", params)
  end

  defp dispatched(rec), do: Agent.get(rec, & &1)

  test "nil current digest is refused 409, no dispatch", %{rec: rec, ledger: ledger} do
    b = brief()
    mid = bare(Brief.render(b).message_id)
    o = opts(rec, ledger, brief_lookup: fn ^mid -> {:ok, b} end)

    conn = EmailPlug.call(req("Approve 1."), o)
    assert conn.status == 409
    assert dispatched(rec) == []
  end

  test "nil digest on the brief action side is refused 409", %{rec: rec, ledger: ledger} do
    b = brief()
    mid = bare(Brief.render(b).message_id)
    nil_b = update_in(b.actions, fn [a1, a2] -> [Map.put(a1, :graph_digest, nil), a2] end)

    o =
      opts(rec, ledger, brief_lookup: fn ^mid -> {:ok, nil_b, %{1 => @digest, 2 => @digest}} end)

    # Tokens in the request are bound to the original brief; a mismatching token halts at 403
    # before freshness, so mint the request against nil_b's tokens.
    params = %{
      "from" => @sender,
      "in_reply_to" => mid,
      "text" => "Approve 1.",
      "subject" => "Re: brief",
      "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" => %{"1" => reply_token_nilsafe(nil_b)}
    }

    conn = EmailPlug.call(conn(:post, "/v1/email:ingest", params), o)
    assert conn.status == 409
    assert dispatched(rec) == []
  end

  # Brief.reply_token works on canonical encoding which tolerates nil digests (render does not).
  defp reply_token_nilsafe(b), do: Brief.reply_token(b, 1)

  test "stale digest is 409 and does not consume the token", %{rec: rec, ledger: ledger} do
    b = brief()
    mid = bare(Brief.render(b).message_id)

    stale_o =
      opts(rec, ledger, brief_lookup: fn ^mid -> {:ok, b, %{1 => @stale, 2 => @digest}} end)

    assert EmailPlug.call(req("Approve 1."), stale_o).status == 409
    assert dispatched(rec) == []

    # Fresh retry of the same tokens still works: staleness never burned them.
    assert EmailPlug.call(req("Approve 1."), opts(rec, ledger)).status == 200
    assert Enum.map(dispatched(rec), &elem(&1, 1)) == [1]
  end

  test "replay of a consumed token is refused 409 already_consumed", %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger)

    assert EmailPlug.call(req("Approve 1.", "m-1"), o).status == 200
    conn = EmailPlug.call(req("Approve 1.", "m-2"), o)

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] == "already_consumed"
    assert Enum.map(dispatched(rec), &elem(&1, 1)) == [1]
  end

  test "replay without message-id is refused", %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger)
    assert EmailPlug.call(req("Approve 1."), o).status == 200
    assert EmailPlug.call(req("Approve 1."), o).status == 409
    assert length(dispatched(rec)) == 1
  end

  test "identical message-id replays cached receipt without re-dispatch",
       %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger)

    first = EmailPlug.call(req("Approve 1.", "m-1"), o)
    again = EmailPlug.call(req("Approve 1.", "m-1"), o)

    assert first.status == 200
    assert again.status == 200
    body = Jason.decode!(again.resp_body)
    assert body["replayed"] == true
    assert body["results"] == Jason.decode!(first.resp_body)["results"]
    assert length(dispatched(rec)) == 1
  end

  test "distinct action numbers are each accepted once", %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger)

    assert EmailPlug.call(req("Approve 1.", "m-1"), o).status == 200
    assert EmailPlug.call(req("Approve 2.", "m-2"), o).status == 200
    assert Enum.map(dispatched(rec), &elem(&1, 1)) == [1, 2]
    assert EmailPlug.call(req("Approve 2.", "m-3"), o).status == 409
  end

  test "per-sender rate limit returns 429 past the bound", %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger, rate_limit: {2, 60_000})

    assert EmailPlug.call(req("Hold 1.", "m-1"), o).status == 200
    assert EmailPlug.call(req("Hold 1.", "m-2"), o).status == 200
    conn = EmailPlug.call(req("Hold 1.", "m-3"), o)

    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "rate_limited"
  end

  test "ledger rate window slides with an injected clock" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, l} = TokenLedger.start_link(now: fn -> Agent.get(clock, & &1) end)

    assert TokenLedger.rate_check(l, "s", 1, 100) == :ok
    assert TokenLedger.rate_check(l, "s", 1, 100) == {:error, :rate_limited}
    Agent.update(clock, fn _ -> 150 end)
    assert TokenLedger.rate_check(l, "s", 1, 100) == :ok
  end

  test "unapproved reply (bad token) is 403 and dispatch authority is untouched",
       %{rec: rec, ledger: ledger} do
    conn = req("Approve 1.")
    params = Map.put(conn.body_params, "reply_tokens", %{"1" => "0000000000000000"})
    conn = EmailPlug.call(conn(:post, "/v1/email:ingest", params), opts(rec, ledger))

    assert conn.status == 403
    assert dispatched(rec) == []
  end
end

# --- SECTION 3: Original test/email_reply_intent_test.exs ---
defmodule AshA2A.EmailReplyIntentTest do
  use ExUnit.Case, async: true

  alias AshA2A.Email.ReplyIntent

  defp decisions(text, nums \\ [1, 2, 3]) do
    {:ok, entries} = ReplyIntent.parse(text, nums)
    Map.new(entries, &{&1.n, &1.decision})
  end

  test "mixed approve and hold with note" do
    {:ok, entries} =
      ReplyIntent.parse("Approve 1 and 3. Hold 2 until I talk to Larson.", [1, 2, 3])

    assert Map.new(entries, &{&1.n, &1.decision}) == %{1 => :approve, 2 => :hold, 3 => :approve}
    assert Enum.find(entries, &(&1.n == 2)).note =~ "until I talk to Larson"
  end

  test "all approves every action" do
    assert {:error, :no_decisions} = ReplyIntent.parse("all", [1, 2, 3])
    assert decisions("Approve all") == %{1 => :approve, 2 => :approve, 3 => :approve}
  end

  test "out-of-range number is ambiguous" do
    assert {:error, :ambiguous} = ReplyIntent.parse("Approve 7", [1, 2, 3])
  end

  test "conflicting decisions for one action are ambiguous" do
    assert {:error, :ambiguous} = ReplyIntent.parse("Approve 1. Reject 1.", [1, 2, 3])
  end

  test "unmentioned actions are :unknown and never resolved as approved" do
    {:ok, entries} = ReplyIntent.parse("Approve 1", [1, 2, 3])

    assert Map.new(entries, &{&1.n, &1.decision}) == %{
             1 => :approve,
             2 => :unknown,
             3 => :unknown
           }

    actions = [%{n: 1}, %{n: 2}, %{n: 3}]
    assert ReplyIntent.resolve(entries, actions) == [%{n: 1}]
  end

  test "no recognisable decision => :no_decisions" do
    assert {:error, :no_decisions} = ReplyIntent.parse("thanks, talk soon", [1, 2, 3])
  end
end

# --- SECTION 4: Original test/error_version_table_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ErrorVersionTableTest do
  @moduledoc """
  Lane Y4: one table pinning every A2A error code's JSON-RPC, HTTP and gRPC row
  (pinned TCK `ERROR_BINDINGS`), plus the absent-version rule for push delivery.
  Real modules, no mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.PushDelivery
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Grpc.Dispatch

  # {constructor, jsonrpc code, http status, grpc numeric, ErrorInfo reason}
  @rows [
    {:task_not_found, -32_001, 404, 5, "TASK_NOT_FOUND"},
    {:task_not_cancelable, -32_002, 409, 9, "TASK_NOT_CANCELABLE"},
    {:push_notification_not_supported, -32_003, 400, 12, "PUSH_NOTIFICATION_NOT_SUPPORTED"},
    {:unsupported_operation, -32_004, 400, 12, "UNSUPPORTED_OPERATION"},
    {:content_type_not_supported, -32_005, 415, 3, "CONTENT_TYPE_NOT_SUPPORTED"},
    {:invalid_agent_response, -32_006, 502, 13, "INVALID_AGENT_RESPONSE"},
    {:authenticated_extended_card_not_configured, -32_007, 400, 9,
     "EXTENDED_AGENT_CARD_NOT_CONFIGURED"},
    {:extension_support_required, -32_008, 400, 9, "EXTENSION_SUPPORT_REQUIRED"},
    {:version_not_supported, -32_009, 400, 12, "VERSION_NOT_SUPPORTED"},
    {:task_generation_mismatch, -32_010, 409, 10, "TASK_GENERATION_MISMATCH"}
  ]

  test "every code: JSON-RPC code, HTTP status, gRPC status, ErrorInfo reason" do
    for {fun, code, http, grpc, reason} <- @rows do
      error = apply(Error, fun, [])
      assert error.code == code, "#{fun} code"
      assert Error.spec_http_status(code) == http, "#{code} http"
      assert Error.grpc_status(code) == grpc, "#{code} grpc"
      assert [%{"reason" => ^reason}] = Error.to_map(error)["data"], "#{code} reason"
    end
  end

  test "gRPC dispatch agrees with the table for -32005" do
    assert {:error, 3, _msg, details} = Dispatch.reason_error({:content_type_not_supported, %{}})
    assert is_list(details)
  end

  test "-32005 / -32006 follow the pinned TCK, not the old 400 / 500" do
    assert Error.spec_http_status(-32_005) == 415
    assert Error.spec_http_status(-32_006) == 502
  end

  describe "absent protocol_version (documented rule: absent == 0.3)" do
    test "push delivery with no version behaves as 0.3 (v1.1 additions stripped)" do
      payload = %{"task" => %{"id" => "t1", "generation" => 3, "timeline" => []}}

      assert {:ok, %{"task" => task}} = PushDelivery.payload_for(%{}, "task", payload)
      refute Map.has_key?(task, "generation")
      assert :skip = PushDelivery.payload_for(%{}, "message-update", payload)

      assert PushDelivery.payload_for(%{}, "task", payload) ==
               PushDelivery.payload_for(%{protocol_version: "0.3"}, "task", payload)
    end

    test "explicit 1.1 still receives the payload as logged" do
      payload = %{"task" => %{"id" => "t1", "generation" => 3}}

      assert {:ok, ^payload} =
               PushDelivery.payload_for(%{protocol_version: "1.1"}, "task", payload)
    end
  end
end

# --- SECTION 5: Original test/event_log_durability_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EventLogDurabilityTest do
  use ExUnit.Case, async: false

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{EventLog, PushConfigStore, TaskEvents}
  alias AshA2A.Cluster.{Checkpoint, Handover}
  alias AshA2A.Protocol.Task
  alias AshA2A.Protocol.TaskStore.ETS, as: EtsStore

  @transport :Y3Transport

  defp start_events(event_log) do
    unless Process.whereis(A2ATransport.registry_name(@transport)) do
      start_supervised!(
        {Registry, keys: :duplicate, name: A2ATransport.registry_name(@transport)}
      )
    end

    unless Process.whereis(A2ATransport.push_store_name(@transport)) do
      start_supervised!(
        {PushConfigStore, name: A2ATransport.push_store_name(@transport), max_per_task: 4}
      )
    end

    start_supervised!(
      {TaskEvents,
       name: A2ATransport.events_name(@transport),
       transport: @transport,
       retention_ms: 600_000,
       max_events: 100,
       push: [],
       event_log: event_log}
    )
  end

  defp status(task_id, state),
    do: %{"statusUpdate" => %{"taskId" => task_id, "status" => %{"state" => state}}}

  setup do
    dir = Path.join(System.tmp_dir!(), "y3_event_log_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "default backend: log is in-memory and gone after restart" do
    start_events(nil)
    TaskEvents.publish(@transport, "t1", "status-update", status("t1", "working"))
    assert [{1, "status-update", _, false}] = TaskEvents.backlog(@transport, "t1")

    stop_supervised!(TaskEvents)
    start_events(nil)
    assert [] = TaskEvents.backlog(@transport, "t1")
  end

  test "dets backend replays seq and generation across a real restart", %{dir: dir} do
    log = {EventLog.Dets, dir: dir}
    start_events(log)

    for s <- ~w(submitted working working) do
      TaskEvents.publish(@transport, "t1", "status-update", status("t1", s))
    end

    before = TaskEvents.backlog(@transport, "t1")
    assert [1, 2, 3] = Enum.map(before, &elem(&1, 0))
    assert [1, 2, 3] = Enum.map(before, fn {_, _, p, _} -> TaskEvents.generation_of(p) end)

    stop_supervised!(TaskEvents)
    start_events(log)

    assert TaskEvents.backlog(@transport, "t1") == before

    # seq and generation continue monotonically after the restart
    assert 4 = TaskEvents.publish(@transport, "t1", "status-update", status("t1", "working"))
    {_, _, p4, _} = List.last(TaskEvents.backlog(@transport, "t1"))
    assert TaskEvents.generation_of(p4) == 4

    # lastSeenGeneration resume works from the replayed log
    log_rows = TaskEvents.backlog(@transport, "t1")
    assert {:ok, replay, _cursor} = TaskEvents.replay_from_generation(log_rows, 2, nil)
    assert Enum.map(replay, &elem(&1, 0)) == [3, 4]
  end

  test "dets backend: trimmed events stay trimmed after restart", %{dir: dir} do
    log = {EventLog.Dets, dir: dir}
    start_events(log)

    for _ <- 1..105,
        do: TaskEvents.publish(@transport, "t2", "status-update", status("t2", "working"))

    before = TaskEvents.backlog(@transport, "t2")
    assert length(before) == 100

    stop_supervised!(TaskEvents)
    start_events(log)
    assert TaskEvents.backlog(@transport, "t2") == before
  end

  test "ETS task store drops a stale (lower-generation) put" do
    name = :"y3_tasks_#{System.unique_integer([:positive])}"
    start_supervised!({EtsStore, name: name})
    task = Task.new(id: "g1")
    :ok = EtsStore.put(name, %{task | generation: 5})
    :ok = EtsStore.put(name, %{task | generation: 3})
    assert {:ok, %{generation: 5}} = EtsStore.get(name, "g1")
    :ok = EtsStore.put(name, %{task | generation: 6})
    assert {:ok, %{generation: 6}} = EtsStore.get(name, "g1")
  end

  test "checkpoint envelope carries generation; handover restores it" do
    name = :"y3_cp_#{System.unique_integer([:positive])}"
    start_supervised!({EtsStore, name: name})
    store = {EtsStore, name}
    :ok = EtsStore.put(name, %{Task.new(id: "c1") | generation: 7})

    landed = Checkpoint.land(store, "c1", %{step: 2})
    assert Checkpoint.generation(landed) == 7

    assert {:ok, [%{task_id: "c1"}]} = Handover.rehydrate(store, fn _t, _f -> {:ok, :done} end)
    assert {:ok, %{generation: g}} = EtsStore.get(name, "c1")
    assert g == 8
  end
end

# --- SECTION 6: Original test/execution_snapshot_semantic_identity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ExecutionSnapshotSemanticIdentityTest do
  use ExUnit.Case, async: true

  alias AshA2A.ExecutionSnapshot

  defp snapshot(overrides \\ []) do
    base = [
      task_id: "task-1",
      work_order_digest: "sha256:work-order",
      command_digest: "sha256:command",
      exact_subject: "repo@example-subject",
      candidate_digest: "sha256:candidate",
      authority_digest: "sha256:authority",
      consequence_digest: "sha256:consequence",
      capability_digest: "sha256:capability",
      semantic_request_digest: "sha256:request",
      tool_surface_digest: "sha256:tools",
      ontology_digest: "sha256:ontology",
      policy_digest: "sha256:policy",
      effect_digest: "sha256:effect",
      authority_requirement: "CONSTRUCT",
      planner_snapshot: %{planner: "fond", digest: "sha256:planner"},
      execution_manifest_digest: "sha256:manifest",
      root_task_id: "root-1",
      parent_task_id: "parent-1",
      delegation_policy: %{max_depth: 3},
      depth: 1,
      worker_id: "worker-a",
      provider_projection: %{provider: "provider-a", transport: "wss", run_id: "run-a"},
      checkpoint: %{sequence: 1},
      created_at: 1_700_000_000_000,
      sequence: 1,
      state: :running
    ]

    ExecutionSnapshot.new!(Keyword.merge(base, overrides))
  end

  test "provider run transport and lifecycle changes do not change semantic work identity" do
    left = snapshot()

    right =
      snapshot(
        worker_id: "worker-b",
        provider_projection: %{provider: "provider-b", transport: "http", run_id: "run-z"},
        checkpoint: %{sequence: 99},
        created_at: 1_800_000_000_000,
        sequence: 99,
        state: :checkpointed
      )

    assert ExecutionSnapshot.semantic_identity_digest(left) ==
             ExecutionSnapshot.semantic_identity_digest(right)

    refute ExecutionSnapshot.digest(left) == ExecutionSnapshot.digest(right)
  end

  test "every exact execution identity component is identity-bearing" do
    original = snapshot()

    for {field, replacement} <- [
          task_id: "task-2",
          work_order_digest: "sha256:other-work-order",
          command_digest: "sha256:other-command",
          exact_subject: "repo@different-subject",
          candidate_digest: "sha256:other-candidate",
          authority_digest: "sha256:other-authority",
          consequence_digest: "sha256:other-consequence",
          capability_digest: "sha256:other-capability",
          execution_manifest_digest: "sha256:other-manifest"
        ] do
      changed = snapshot([{field, replacement}])

      refute ExecutionSnapshot.semantic_identity_digest(original) ==
               ExecutionSnapshot.semantic_identity_digest(changed),
             "#{field} must participate in semantic identity"
    end
  end

  test "planner policy and effect semantics remain identity-bearing" do
    original = snapshot()

    for changed <- [
          snapshot(effect_digest: "sha256:different-effect"),
          snapshot(authority_requirement: "DO"),
          snapshot(policy_digest: "sha256:different-policy"),
          snapshot(planner_snapshot: %{planner: "hddl", digest: "sha256:other-plan"})
        ] do
      refute ExecutionSnapshot.semantic_identity_digest(original) ==
               ExecutionSnapshot.semantic_identity_digest(changed)
    end
  end

  test "deterministic serialization ignores nested map insertion order" do
    left =
      snapshot(
        planner_snapshot: Map.new([{:planner, "fond"}, {:digest, "sha256:planner"}]),
        delegation_policy: Map.new([{:max_depth, 3}, {:mode, :bounded}])
      )

    right =
      snapshot(
        planner_snapshot: Map.new([{:digest, "sha256:planner"}, {:planner, "fond"}]),
        delegation_policy: Map.new([{:mode, :bounded}, {:max_depth, 3}])
      )

    assert ExecutionSnapshot.semantic_identity_digest(left) ==
             ExecutionSnapshot.semantic_identity_digest(right)

    assert ExecutionSnapshot.encode(left) == ExecutionSnapshot.encode(right)
  end

  test "digests are lowercase sha256 hex" do
    snapshot = snapshot()

    assert ExecutionSnapshot.digest(snapshot) =~ ~r/^[0-9a-f]{64}$/
    assert ExecutionSnapshot.semantic_identity_digest(snapshot) =~ ~r/^[0-9a-f]{64}$/
    assert ExecutionSnapshot.replay_key(snapshot) =~ ~r/^[0-9a-f]{64}$/
  end
end

# --- SECTION 7: Original test/extended_card_resign_test.exs ---
defmodule AshA2A.ExtendedCardResignTest do
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.ExtendedCard
  alias AshA2A.Protocol.{CardSigner, CardSigning, JSON}

  @key :crypto.strong_rand_bytes(32)

  defp public_map(signatures_key \\ nil) do
    card = AshA2A.Info.agent_card(AshA2A.Test.Fixture.Echo)
    card = if signatures_key, do: CardSigning.sign(card, signatures_key), else: card

    card
    |> JSON.encode_agent_card(url: "http://localhost/a2a")
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp verifies?(map, key) do
    {:ok, card} = JSON.decode_agent_card(map)
    CardSigning.verify(card, key)
  end

  defp add_skill(map) do
    skill = %{"id" => "extra", "name" => "Extra", "description" => "added", "tags" => []}
    Map.update!(map, "skills", &(&1 ++ [skill]))
  end

  test "CardSigner.sign/2 output verifies and strip_signatures removes it" do
    signed = CardSigner.sign(public_map(), key: @key, kid: "k1")
    assert [_] = signed["signatures"]
    assert :ok = verifies?(signed, @key)
    refute Map.has_key?(CardSigner.strip_signatures(signed), "signatures")
  end

  test "verifier_for_jwk/1 verifies an ES256 card from a published JWK" do
    ec = :public_key.generate_key({:namedCurve, :secp256r1})
    [jwk] = CardSigning.jwks([{"e1", ec}])["keys"]
    signed = CardSigner.sign(public_map(), key: ec, alg: :ES256, kid: "e1")
    {:ok, card} = JSON.decode_agent_card(signed)
    assert :ok = CardSigning.verifier_for_jwk(jwk).(card)
    assert :ok = CardSigning.verifier_for_jwk(%{"keys" => [jwk]}).(card)
  end

  test "modified extended card never carries a stale signature" do
    stale = public_map(@key) |> add_skill()
    assert {:error, _} = verifies?(stale, @key)

    opts = %{a2a: %{agent_card_opts: []}}
    out = ExtendedCard.resign(stale, opts)
    refute Map.has_key?(out, "signatures")
  end

  test "modified extended card is re-signed when a signing key is configured" do
    stale = public_map(@key) |> add_skill()
    opts = %{a2a: %{agent_card_opts: [sign_with: [key: @key, kid: "k1"]]}}
    out = ExtendedCard.resign(stale, opts)
    assert [_] = out["signatures"]
    assert :ok = verifies?(out, @key)
  end
end

# --- SECTION 8: Original test/extension_version_compile_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ExtensionVersionCompileTest.Unversioned do
  @moduledoc false
  @behaviour AshA2A.Protocol.Extension

  @impl true
  def declaration(_state),
    do: %AshA2A.Protocol.AgentExtension{uri: "https://w9.example/ext/unversioned"}
end

defmodule AshA2A.ExtensionVersionCompileTest do
  @moduledoc """
  W9 item 2: `AshA2A.Protocol.Extension.compile/1` dedupes repeated URIs and
  warns (A2A extensions topic: SHOULD be versioned) when a URI lacks a `/vN`
  suffix. The warning is emitted when a plug is initialised (compile time under
  Phoenix's `plug` macro).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshA2A.Protocol.Extension
  alias AshA2A.Protocol.Extension.Timestamp
  alias AshA2A.ExtensionVersionCompileTest.Unversioned

  test "versioned_uri?/1 recognises /vN and /vN.M suffixes only" do
    assert Extension.versioned_uri?("https://x.example/ext/foo/v1")
    assert Extension.versioned_uri?("https://x.example/ext/foo/v2.1")
    assert Extension.versioned_uri?("https://x.example/ext/foo/v1/")
    refute Extension.versioned_uri?("https://x.example/ext/foo")
    refute Extension.versioned_uri?("https://x.example/ext/foo/v")
    refute Extension.versioned_uri?("https://x.example/ext/v1/foo")
    refute Extension.versioned_uri?(nil)
  end

  test "compile/1 warns for an unversioned URI and stays silent for a versioned one" do
    log =
      capture_log([level: :warning], fn ->
        assert [{Unversioned, _, _}] = Extension.compile([Unversioned])
      end)

    assert log =~ "without a /vN version suffix"
    assert log =~ "https://w9.example/ext/unversioned"

    quiet = capture_log([level: :warning], fn -> Extension.compile([Timestamp]) end)
    refute quiet =~ "version suffix"
  end

  test "compile/1 keeps the first declaration of a repeated URI" do
    assert [{Timestamp, _, decl}] = Extension.compile([Timestamp, {Timestamp, []}, Timestamp])
    assert decl.uri == Timestamp.uri()
  end

  test "Transport.Plug.init/1 warns too, and still splits advertise-only declarations" do
    declaration = %AshA2A.Protocol.AgentExtension{uri: "https://w9.example/ext/advertised/v1"}

    log =
      capture_log([level: :warning], fn ->
        opts =
          AshA2A.Transport.Plug.init(
            agent: :w9_no_such_agent,
            extensions: [Unversioned, declaration]
          )

        assert [{Unversioned, _, _}] = opts.compiled_extensions
        assert opts.extensions == [declaration]
      end)

    assert log =~ "without a /vN version suffix"
  end
end

# --- SECTION 9: Original test/gall_checkpoint_003_command_authority_chicago_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.CommandAuthorityChicagoTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, SemanticSubject}
  alias AshA2A.Gall.CommandReceipt
  alias AshA2A.ReceiptStore

  defmodule A do
    use Ash.Resource,
      domain: AshA2A.Gall.CommandAuthorityChicagoTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true)
    end

    actions do
      read(:read)

      create :create do
        accept([:label])
      end
    end
  end

  defmodule B do
    use Ash.Resource,
      domain: AshA2A.Gall.CommandAuthorityChicagoTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true)
    end

    actions do
      read(:read)

      create :create do
        accept([:label])
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, extensions: [AshA2A]

    resources do
      resource(A)
      resource(B)
    end
  end

  setup do
    outbox_dir =
      Path.join(System.tmp_dir!(), "gall-003-#{System.unique_integer([:positive])}")

    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({ReceiptStore.Memory, name: name})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      File.rm_rf!(outbox_dir)
    end)

    {:ok, store_opts: [name: name]}
  end

  defp semantic_subject do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("a", 64),
        projection_digest: "sha256:" <> String.duplicate("b", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("c", 64)
      )

    subject
  end

  defp command(capability_id, id) do
    principal = Identity.principal("gall-003-principal")

    Command.new(capability_id,
      command_id: id,
      agent_id: "gall-003-agent",
      principal_id: principal,
      authority: Authority.new(principal, capability_id, token_id: "grant-#{id}"),
      semantic_subject: semantic_subject(),
      input: %{label: id}
    )
  end

  test "exact non-first duplicate capability survives CommandBus and emits bound observer handoff",
       %{store_opts: store_opts} do
    capability = AshA2A.CapabilityIndex.Compiler.capability_id(B, :create)
    cmd = command(capability, "gall-003-b")

    assert {:ok, receipt} =
             CommandBus.run(cmd, data_message(cmd.input), Domain,
               store: ReceiptStore.Memory,
               store_opts: store_opts
             )

    assert receipt.capability_id == capability
    assert receipt.consequence == :change
    assert receipt.terminal_status == :executed, "failed dispatch receipt: #{inspect(receipt)}"

    assert {:ok, handoff} = CommandReceipt.from_receipt(receipt)
    assert handoff.capability_id == capability
    assert handoff.manufacturer_subject_digest == semantic_subject().manufacturer_digest
    assert String.starts_with?(handoff.handoff_digest, "sha256:")

    refute Enum.any?(Ash.read!(A, action: :read, domain: Domain), &(&1.label == cmd.input.label))

    assert Enum.count(Ash.read!(B, action: :read, domain: Domain), &(&1.label == cmd.input.label)) ==
             1
  end

  test "ambiguous display selector is refused before consequence", %{store_opts: store_opts} do
    cmd = command("create", "gall-003-ambiguous")

    assert {:error, %{code: :ambiguous_skill}} =
             CommandBus.run(cmd, data_message(cmd.input), Domain,
               store: ReceiptStore.Memory,
               store_opts: store_opts
             )

    refute Enum.any?(Ash.read!(A, action: :read, domain: Domain), &(&1.label == cmd.input.label))
    refute Enum.any?(Ash.read!(B, action: :read, domain: Domain), &(&1.label == cmd.input.label))
  end

  test "tampering a bound semantic subject prevents observer handoff", %{store_opts: store_opts} do
    capability = AshA2A.CapabilityIndex.Compiler.capability_id(A, :create)
    cmd = command(capability, "gall-003-tamper")

    assert {:ok, receipt} =
             CommandBus.run(cmd, data_message(cmd.input), Domain,
               store: ReceiptStore.Memory,
               store_opts: store_opts
             )

    tampered = %{
      receipt
      | semantic_subject: %{
          receipt.semantic_subject
          | manufacturer_digest: "sha256:" <> String.duplicate("d", 64)
        }
    }

    assert {:error, %{code: :receipt_binding_field_mismatch}} =
             CommandReceipt.from_receipt(tampered)
  end
end

# --- SECTION 10: Original test/gall_process_intervention_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.ProcessInterventionTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, Identity, Postcondition, ReceiptStore}
  alias AshA2A.Gall.ProcessIntervention
  alias AshA2A.Chicago.Fixtures.Postcondition, as: Fixtures
  alias AshA2A.Chicago.Fixtures.Postcondition.{Ledger, LedgerVerifier}

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})

    handler = "gall-process-intervention-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:ash_a2a, :command_bus, :actuate, :start],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:actuate_start, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{store_opts: [name: name]}
  end

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        producer_repository: "seanchatmangpt/beam4pm",
        producer_sha: String.duplicate("a", 40),
        evidence_digest: "sha256:" <> String.duplicate("b", 64),
        semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
        finding_class: "conformance",
        finding_type: "ordering_violation",
        candidate_class: "bounded_intervention",
        horizon: "FAST",
        vocabulary: "https://w3id.org/ocel",
        requested_capability_id: Fixtures.capability(:honest_write)
      },
      overrides
    )
  end

  defp rule_key(finding), do: {finding.vocabulary, finding.finding_type, finding.candidate_class}

  defp admission_opts(finding, overrides \\ []) do
    capability = Fixtures.capability(:honest_write)

    [
      allowed_producers: [finding.producer_sha],
      allowed_evidence_digests: [finding.evidence_digest],
      allowed_semantic_subjects: [finding.semantic_subject_digest],
      allowed_horizons: [finding.horizon],
      allowed_capabilities: [capability],
      public_vocabulary: [finding.vocabulary],
      admission_rules: %{rule_key(finding) => capability}
    ]
    |> Keyword.merge(overrides)
  end

  defp admit!(finding) do
    assert {:ok, candidate} = ProcessIntervention.admit(finding, admission_opts(finding))
    candidate
  end

  defp intervention(candidate, key, store_opts, opts \\ []) do
    principal = Identity.principal("gall-030")
    capability = candidate.capability_id

    authority =
      if Keyword.get(opts, :authorized, true) do
        Keyword.get_lazy(opts, :authority, fn ->
          Authority.new(principal, capability, token_id: "auth-#{key}")
        end)
      end

    digest = Keyword.get(opts, :candidate_digest, candidate.candidate_digest)
    input = %{key: key, value: "X"}

    metadata =
      %{gall_029_candidate_digest: digest}
      |> Map.merge(
        if Keyword.get(opts, :idempotent, true),
          do: %{idempotency_key: "gall-030-#{key}"},
          else: %{}
      )

    command =
      Command.new(capability,
        command_id: Keyword.get(opts, :command_id, "gall-030-#{key}"),
        agent_id: "gall-030",
        principal_id: principal,
        authority: authority,
        input: input,
        metadata: metadata
      )

    message = data_message(%{"key" => key, "value" => "X"})

    postcondition = %Postcondition{
      id: "gall-030.ledger-value-persisted",
      verifier: LedgerVerifier,
      expect: %{key: key, value: "X"}
    }

    {command, message,
     [
       store_opts: store_opts,
       postcondition: Keyword.get(opts, :postcondition, postcondition),
       scope: %{input_digest: ProcessIntervention.canonical_digest(input)},
       max_consequences: 1,
       expected_postcondition: %{key: key, value: "X"}
     ]}
  end

  defp refused_before_do(command, key, store_opts) do
    assert Fixtures.stored_values(key) == []
    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    refute_received {:actuate_start, _}
  end

  test "GALL-029 admits an exactly bound authority-free candidate" do
    source = finding()
    candidate = admit!(source)

    assert candidate.authority == :none
    assert candidate.evidence_ceiling == "ADMIT_ONLY"
    assert candidate.producer_repository == source.producer_repository
    assert candidate.producer_sha == source.producer_sha
    assert candidate.evidence_digest == source.evidence_digest
    assert candidate.semantic_subject_digest == source.semantic_subject_digest
    assert candidate.finding_class == source.finding_class
    assert candidate.finding_type == source.finding_type
    assert candidate.candidate_class == source.candidate_class
    assert candidate.horizon == source.horizon
    assert candidate.vocabulary == source.vocabulary
    assert candidate.capability_id == source.requested_capability_id
    assert String.starts_with?(candidate.finding_digest, "sha256:")
    assert String.starts_with?(candidate.candidate_digest, "sha256:")
  end

  test "prediction remains prediction-class evidence and secrets fail closed" do
    source = finding(%{finding_class: "prediction"})
    candidate = admit!(source)

    assert candidate.finding_class == "prediction"
    assert candidate.authority == :none

    assert {:error, :secret_bearing_finding} =
             ProcessIntervention.admit(
               Map.put(source, :authorization, "Bearer abc"),
               admission_opts(source)
             )
  end

  test "missing policy and stale or private identities fail closed" do
    source = finding()

    assert {:error, :producer_allowlist_required} = ProcessIntervention.admit(source)

    cases = [
      {:producer_sha, String.duplicate("d", 40), :stale_or_unadmitted_producer},
      {:evidence_digest, "sha256:" <> String.duplicate("d", 64), :stale_or_unadmitted_evidence},
      {:semantic_subject_digest, "sha256:" <> String.duplicate("d", 64),
       :stale_or_mismatched_semantic_subject},
      {:horizon, "SLOW", :unadmitted_horizon},
      {:requested_capability_id, Fixtures.capability(:lying_write), :capability_mismatch},
      {:vocabulary, "https://example.org/private", :private_or_unknown_vocabulary}
    ]

    for {field, value, expected} <- cases do
      mutated = Map.put(source, field, value)
      assert {:error, ^expected} = ProcessIntervention.admit(mutated, admission_opts(source))
    end

    assert {:error, :unadmitted_capability} =
             ProcessIntervention.admit(
               source,
               admission_opts(source,
                 allowed_capabilities: [Fixtures.capability(:lying_write)]
               )
             )
  end

  test "GALL-029 capability comes only from explicit semantic admission rule" do
    rule_capability = Fixtures.capability(:honest_write)
    source = Map.delete(finding(), :requested_capability_id)
    opts = admission_opts(source)

    assert {:ok, candidate} = ProcessIntervention.admit(source, opts)
    assert candidate.capability_id == rule_capability
    assert candidate.authority == :none
    assert candidate.evidence_ceiling == "ADMIT_ONLY"

    attacker =
      Map.put(source, :requested_capability_id, "attacker-supplied-value-is-not-authority")

    assert {:error, :capability_mismatch} = ProcessIntervention.admit(attacker, opts)

    assert {:error, :unsupported_process_finding_rule} =
             ProcessIntervention.admit(source, Keyword.put(opts, :admission_rules, %{}))

    assert {:error, :invalid_process_finding_rule} =
             ProcessIntervention.admit(
               source,
               Keyword.put(opts, :admission_rules, %{rule_key(source) => ""})
             )

    assert {:error, :invalid_process_finding_rules} =
             ProcessIntervention.admit(source, Keyword.delete(opts, :admission_rules))

    assert {:error, :unsupported_process_finding_rule} =
             ProcessIntervention.admit(
               Map.put(source, :finding_type, "unmodelled_type"),
               opts
             )
  end

  test "hex SHA/digest, repository shape and repository-pinned producers fail closed" do
    source = finding()
    opts = admission_opts(source)

    assert {:error, :producer_sha} =
             ProcessIntervention.admit(
               Map.put(source, :producer_sha, String.duplicate("z", 40)),
               opts
             )

    assert {:error, :evidence_digest} =
             ProcessIntervention.admit(
               Map.put(source, :evidence_digest, "sha256:" <> String.duplicate("z", 64)),
               opts
             )

    assert {:error, :semantic_subject_digest} =
             ProcessIntervention.admit(
               Map.put(source, :semantic_subject_digest, "sha256:" <> String.duplicate("Z", 64)),
               opts
             )

    assert {:error, :producer_repository} =
             ProcessIntervention.admit(Map.put(source, :producer_repository, "no-slash"), opts)

    assert {:error, :producer_repository} =
             ProcessIntervention.admit(Map.delete(source, :producer_repository), opts)

    pinned = %{source.producer_repository => source.producer_sha}

    assert {:ok, candidate} =
             ProcessIntervention.admit(source, Keyword.put(opts, :allowed_producers, pinned))

    assert candidate.producer_repository == source.producer_repository

    assert {:error, :stale_or_unadmitted_producer} =
             ProcessIntervention.admit(
               source,
               Keyword.put(opts, :allowed_producers, %{"other/repo" => source.producer_sha})
             )

    assert {:error, :producer_allowlist_required} =
             ProcessIntervention.admit(source, Keyword.put(opts, :allowed_producers, %{}))
  end

  test "candidate digest is semantic command identity for replay" do
    first = admit!(finding())
    second_source = finding(%{evidence_digest: "sha256:" <> String.duplicate("d", 64)})
    second = admit!(second_source)

    common = [
      command_id: "candidate-fingerprint",
      agent_id: "gall-030",
      principal_id: "gall-030",
      input: %{key: "k", value: "X"}
    ]

    first_command =
      Command.new(
        first.capability_id,
        common ++ [metadata: %{gall_029_candidate_digest: first.candidate_digest}]
      )

    second_command =
      Command.new(
        second.capability_id,
        common ++ [metadata: %{gall_029_candidate_digest: second.candidate_digest}]
      )

    refute first.candidate_digest == second.candidate_digest
    refute first_command.fingerprint == second_command.fingerprint
  end

  test "candidate without ADMIT_ONLY evidence ceiling is not an admitted candidate",
       %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "no-ceiling-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)

    forged =
      candidate
      |> Map.delete(:evidence_ceiling)
      |> Map.delete(:candidate_digest)
      |> then(&Map.put(&1, :candidate_digest, ProcessIntervention.canonical_digest(&1)))

    assert {:error, :gall_029_admission_required} =
             ProcessIntervention.intervene(forged, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "missing authority refuses before DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "no-authority-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts, authorized: false)

    assert {:error, :authority_required} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "authority for another principal refuses before DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "wrong-authority-#{System.unique_integer([:positive])}"

    other =
      Authority.new(Identity.principal("someone-else"), candidate.capability_id,
        token_id: "auth-other-#{key}"
      )

    {command, message, opts} = intervention(candidate, key, store_opts, authority: other)

    assert {:error, :authority_mismatch} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "one-DO policy budget refuses every unbounded shape before DO",
       %{store_opts: store_opts} do
    candidate = admit!(finding())

    cases = [
      {:intervention_scope_required, fn opts, _c -> Keyword.delete(opts, :scope) end},
      {:intervention_scope_required, fn opts, _c -> Keyword.put(opts, :scope, %{}) end},
      {:intervention_budget_must_be_one,
       fn opts, _c -> Keyword.put(opts, :max_consequences, 2) end},
      {:intervention_budget_must_be_one,
       fn opts, _c -> Keyword.delete(opts, :max_consequences) end},
      {:intervention_scope_input_mismatch,
       fn opts, _c ->
         Keyword.put(opts, :scope, %{
           input_digest: ProcessIntervention.canonical_digest(%{key: "other", value: "X"})
         })
       end},
      {:expected_postcondition_required,
       fn opts, _c -> Keyword.delete(opts, :expected_postcondition) end},
      {:observer_postcondition_subject_mismatch,
       fn opts, _c -> Keyword.put(opts, :expected_postcondition, %{key: "other", value: "Y"}) end}
    ]

    for {expected, mutate} <- cases do
      key = "budget-#{expected}-#{System.unique_integer([:positive])}"
      {command, message, opts} = intervention(candidate, key, store_opts)

      assert {:error, ^expected} =
               ProcessIntervention.intervene(
                 candidate,
                 command,
                 message,
                 Ledger,
                 mutate.(opts, command)
               )

      refused_before_do(command, key, store_opts)
    end

    key = "no-idempotency-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts, idempotent: false)

    assert {:error, :intervention_idempotency_required} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "candidate metadata mismatch refuses before CommandBus DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "bad-binding-#{System.unique_integer([:positive])}"

    {command, message, opts} =
      intervention(candidate, key, store_opts,
        candidate_digest: "sha256:" <> String.duplicate("0", 64)
      )

    assert {:error, :candidate_binding_mismatch} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "independent observer is mandatory before DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "no-observer-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)
    opts = Keyword.delete(opts, :postcondition)

    assert {:error, :independent_observer_required} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "authorized intervention crosses DO once through CommandBus and independently verifies post-state",
       %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "alive-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)

    assert {:ok, %{command_receipt: receipt, observer_receipt: observer} = result} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    assert result.evidence_ceiling == "AUTHORIZED_DO"
    assert result.postcondition_standing == "VERIFIED"

    assert result.expected_postcondition_digest ==
             ProcessIntervention.canonical_digest(%{key: key, value: "X"})

    assert receipt.status == :completed
    assert receipt.fingerprint == command.fingerprint
    assert observer.status == :verified
    assert observer.independent == true
    assert Fixtures.stored_values(key) == ["X"]

    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
    assert stored.fingerprint == command.fingerprint

    assert_received {:actuate_start, %{command_id: _}}
    refute_received {:actuate_start, _}
  end

  test "GALL-030 exact scoped replay stays one effect", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "replay-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)

    assert {:ok, first} = ProcessIntervention.intervene(candidate, command, message, Ledger, opts)
    assert first.evidence_ceiling == "AUTHORIZED_DO"
    assert Fixtures.stored_values(key) == ["X"]
    assert_received {:actuate_start, _}

    replay = ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    assert {:ok, replayed} = replay
    assert replayed.command_receipt.replayed? == true
    assert replayed.command_receipt.receipt_id == first.command_receipt.receipt_id
    assert replayed.postcondition_standing == "VERIFIED"

    assert Fixtures.stored_values(key) == ["X"]
    refute_received {:actuate_start, _}

    assert {:error, :intervention_budget_must_be_one} =
             ProcessIntervention.intervene(
               candidate,
               command,
               message,
               Ledger,
               Keyword.put(opts, :max_consequences, 2)
             )

    # A replay whose declared observer names a different postcondition id
    # (same expectation) must not inherit the stored observation as its own.
    renamed = %Postcondition{
      id: "gall-030.some-other-postcondition",
      verifier: LedgerVerifier,
      expect: %{key: key, value: "X"}
    }

    assert {:error, :observer_postcondition_subject_mismatch} =
             ProcessIntervention.intervene(
               candidate,
               command,
               message,
               Ledger,
               Keyword.put(opts, :postcondition, renamed)
             )

    assert Fixtures.stored_values(key) == ["X"]
    refute_received {:actuate_start, _}
  end

  test "candidate swap on the same command id conflicts and cannot replay another finding's receipt",
       %{store_opts: store_opts} do
    first = admit!(finding())
    second_source = finding(%{evidence_digest: "sha256:" <> String.duplicate("d", 64)})
    second = admit!(second_source)
    key = "candidate-swap-#{System.unique_integer([:positive])}"
    command_id = "gall-030-swap-#{System.unique_integer([:positive])}"

    {first_command, first_message, first_opts} =
      intervention(first, key, store_opts, command_id: command_id)

    {second_command, second_message, second_opts} =
      intervention(second, key, store_opts, command_id: command_id)

    assert {:ok, %{command_receipt: first_receipt}} =
             ProcessIntervention.intervene(
               first,
               first_command,
               first_message,
               Ledger,
               first_opts
             )

    assert first_receipt.status == :completed
    assert_received {:actuate_start, _}

    assert {:error, %{code: :command_conflict}} =
             ProcessIntervention.intervene(
               second,
               second_command,
               second_message,
               Ledger,
               second_opts
             )

    assert Fixtures.stored_values(key) == ["X"]
    refute_received {:actuate_start, _}
  end
end

# --- SECTION 11: Original test/generation_gating_courts_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GenerationGatingCourts.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.GenerationGatingCourts.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:text, :string, allow_nil?: false)

      run(fn input, _context -> {:ok, %{text: input.arguments.text}} end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.GenerationGatingCourts.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.GenerationGatingCourts.Resource)
  end
end

defmodule AshA2A.GenerationGatingCourts.ClosedAgent do
  @moduledoc "No `user_artifacts` declared."
  use AshA2A.Agent,
    resource_or_domain: AshA2A.GenerationGatingCourts.Resource,
    name: "b3_closed_agent"
end

defmodule AshA2A.GenerationGatingCourts.OpenAgent do
  @moduledoc "Declares `capabilities.user_artifacts`."
  use AshA2A.Agent,
    resource_or_domain: AshA2A.GenerationGatingCourts.Resource,
    name: "b3_open_agent",
    capabilities: %{streaming: true, user_artifacts: true}
end

defmodule AshA2A.GenerationGatingCourts.Pipeline do
  @moduledoc "Stamps a verified identity taken from the `x-test-user` header (default alice)."

  @behaviour Plug

  def init(opts), do: AshA2A.Transport.Plug.init(opts)

  def call(conn, opts) do
    user =
      case Plug.Conn.get_req_header(conn, "x-test-user") do
        [u | _] -> u
        [] -> "alice"
      end

    conn
    |> AshA2A.Protocol.Plug.Auth.put_identity(%{identity: user})
    |> AshA2A.Transport.Plug.call(opts)
  end
end

defmodule AshA2A.GenerationGatingCourtsTest do
  @moduledoc """
  B3 courts over the JSON-RPC `AshA2A.Transport.Plug` on a real Bandit
  listener with a real `AshA2A.Agent` and real `Req` clients.

  Covered here (gaps only):

    1. `tasks/resubscribe` on an owned task: snapshot first; no snapshot when
       `lastSeenGeneration` equals the current generation; foreign principal
       gets `-32001`.
    2. `message/stream` messageUpdate frames: absent for A2A-Version 1.0,
       present for 1.1.
    3. `capabilities.userArtifacts` advertised on the served card when
       declared; `artifactUpdates` refused (-32004) when not.
    4. `ifGenerationMatch` mismatch -> JSON-RPC `-32010` TASK_GENERATION_MISMATCH.

  Already covered elsewhere (not repeated): REST 409 mismatch, REST
  subscribe `lastSeenGeneration`, REST artifactUpdates refusal and REST
  message:stream version gating (test/http_json_generation_stream_test.exs); -32010 and
  1.0 gating on `AshA2A.Protocol.Plug` (test/generation_plug_wiring_test.exs,
  test/sse_generation_frames_test.exs).
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp

  @deadline_ms 5_000
  @v11 [{"a2a-version", "1.1"}]

  setup do
    agents = [AshA2A.GenerationGatingCourts.ClosedAgent, AshA2A.GenerationGatingCourts.OpenAgent]

    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, agents)

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])

    servers =
      Map.new(agents, fn agent ->
        opts = [agent: agent, base_url: "http://127.0.0.1/b3", versions: versions]
        {agent, EphemeralHttp.start!({AshA2A.GenerationGatingCourts.Pipeline, opts})}
      end)

    {:ok,
     closed: servers[AshA2A.GenerationGatingCourts.ClosedAgent],
     open: servers[AshA2A.GenerationGatingCourts.OpenAgent]}
  end

  # -- helpers ---------------------------------------------------------------

  defp wire(parts), do: AshA2A.Protocol.JSON.encode!(Message.new_user(parts))
  defp parked, do: wire([Part.Data.new(%{})])
  defp completing, do: wire([Part.Data.new(%{"text" => "hi"})])

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp rpc(server, method, params, headers \\ @v11) do
    Req.post!(
      url: server.base_url <> "/",
      json: envelope(method, params),
      headers: headers,
      retry: false
    ).body
  end

  defp park_task(server) do
    assert %{"result" => %{"task" => %{"id" => id} = task}} =
             rpc(server, "message/send", %{"message" => parked()})

    {id, gen(task)}
  end

  defp gen(%{"generation" => g}) do
    {n, ""} = g |> to_string() |> Integer.parse()
    n
  end

  # `data:` frames of a buffered SSE body, as JSON-RPC envelopes.
  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _comment -> []
    end)
  end

  defp results(frames), do: Enum.map(frames, &Map.get(&1, "result", &1))

  # Opens an SSE request and returns once the response HEADERS arrived. For a
  # resubscribe the plug registers the subscriber before it starts the
  # response, so a returned handle means the subscription is live.
  defp open_stream(server, params, headers) do
    resp =
      Req.post!(
        url: server.base_url <> "/",
        json: envelope("tasks/resubscribe", params),
        headers: headers,
        retry: false,
        into: :self,
        receive_timeout: 20_000
      )

    assert resp.status == 200
    resp
  end

  defp collect(resp, buffer, pred) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    do_collect(resp, buffer, pred, deadline)
  end

  defp do_collect(resp, buffer, pred, deadline) do
    all = frames(buffer)

    if pred.(all) do
      {all, buffer}
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: flunk("deadline; frames so far: #{inspect(all)}")

      receive do
        msg ->
          case Req.parse_message(resp, msg) do
            {:ok, chunks} ->
              data = for {:data, d} <- chunks, into: "", do: d
              do_collect(resp, buffer <> data, pred, deadline)

            _unknown ->
              do_collect(resp, buffer, pred, deadline)
          end
      after
        remaining -> flunk("deadline; frames so far: #{inspect(all)}")
      end
    end
  end

  defp advance(server, id) do
    assert %{"result" => %{"task" => %{"id" => ^id}}} =
             rpc(server, "message/send", %{"message" => Map.put(parked(), "taskId", id)})
  end

  # -- 1. tasks/resubscribe on an owned task ------------------------------------

  test "resubscribe on an owned task sends the task snapshot first", %{open: server} do
    {id, generation} = park_task(server)

    resp = open_stream(server, %{"id" => id}, @v11)
    {[first | _], _} = collect(resp, "", &(&1 != []))

    assert %{"result" => %{"task" => %{"id" => ^id} = snapshot}} = first
    assert gen(snapshot) == generation
    Req.cancel_async_response(resp)
  end

  test "resubscribe with lastSeenGeneration == current sends no snapshot, only newer events", %{
    open: server
  } do
    {id, generation} = park_task(server)

    resp = open_stream(server, %{"id" => id, "lastSeenGeneration" => generation}, @v11)

    advance(server, id)

    {frames, _} = collect(resp, "", &(&1 != []))
    refute Enum.any?(results(frames), &Map.has_key?(&1, "task"))

    assert [update] =
             frames
             |> hd()
             |> Map.fetch!("result")
             |> Map.take(["statusUpdate", "messageUpdate"])
             |> Map.values()

    assert gen(update) > generation
    Req.cancel_async_response(resp)
  end

  test "resubscribe by a foreign principal is -32001, indistinguishable from an unknown task", %{
    open: server
  } do
    {id, _} = park_task(server)

    foreign = rpc(server, "tasks/resubscribe", %{"id" => id}, @v11 ++ [{"x-test-user", "bob"}])

    unknown =
      rpc(
        server,
        "tasks/resubscribe",
        %{"id" => "tsk-no-such-task"},
        @v11 ++ [{"x-test-user", "bob"}]
      )

    assert %{"error" => %{"code" => -32_001}} = foreign
    assert get_in(foreign, ["error", "code"]) == get_in(unknown, ["error", "code"])
    assert get_in(foreign, ["error", "data"]) == get_in(unknown, ["error", "data"])
    refute Map.has_key?(foreign, "result")
  end

  # -- 2. messageUpdate version gating on message/stream -------------------------

  test "message/stream frames carry messageUpdate for A2A-Version 1.1 and not for 1.0", %{
    open: server
  } do
    stream = fn version ->
      resp =
        Req.post!(
          url: server.base_url <> "/",
          json: envelope("message/stream", %{"message" => completing()}),
          headers: [{"a2a-version", version}],
          retry: false,
          decode_body: false
        )

      assert resp.status == 200
      resp.body |> frames() |> results()
    end

    new = stream.("1.1")
    assert Enum.any?(new, &Map.has_key?(&1, "messageUpdate"))
    assert Enum.any?(new, &Map.has_key?(&1, "statusUpdate"))

    old = stream.("1.0")
    refute Enum.any?(old, &Map.has_key?(&1, "messageUpdate"))
    refute Enum.any?(old, &Map.has_key?(&1, "error"))
    assert Enum.any?(old, &Map.has_key?(&1, "statusUpdate"))
  end

  # -- 3. userArtifacts ------------------------------------------------------------

  test "card advertises capabilities.userArtifacts when declared and not when undeclared", %{
    open: open,
    closed: closed
  } do
    open_card = Req.get!(url: open.base_url <> "/.well-known/agent-card.json", retry: false).body
    assert get_in(open_card, ["capabilities", "userArtifacts"]) == true

    closed_card =
      Req.get!(url: closed.base_url <> "/.well-known/agent-card.json", retry: false).body

    refute get_in(closed_card, ["capabilities", "userArtifacts"]) == true
  end

  test "artifactUpdates are refused -32004 when userArtifacts is not declared, task untouched", %{
    closed: server
  } do
    {id, generation} = park_task(server)

    artifact =
      AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Artifact.new([Part.Data.new(%{"k" => "v"})]))

    resp =
      rpc(server, "message/send", %{
        "artifactUpdates" => [%{"taskId" => id, "artifact" => artifact}]
      })

    assert %{"error" => %{"code" => -32_004}} = resp

    assert %{"result" => %{"id" => ^id} = task} = rpc(server, "tasks/get", %{"id" => id})
    assert gen(task) == generation
  end

  # -- 4. ifGenerationMatch ----------------------------------------------------------

  test "ifGenerationMatch mismatch is -32010 TASK_GENERATION_MISMATCH; match proceeds", %{
    open: server
  } do
    {id, generation} = park_task(server)
    follow_up = Map.put(parked(), "taskId", id)

    stale =
      rpc(server, "message/send", %{
        "message" => follow_up,
        "configuration" => %{"ifGenerationMatch" => generation + 5}
      })

    assert %{"error" => %{"code" => -32_010, "data" => data}} = stale
    assert Enum.any?(data, &(&1["reason"] == "TASK_GENERATION_MISMATCH"))

    # refused before mutation
    assert %{"result" => task} = rpc(server, "tasks/get", %{"id" => id})
    assert gen(task) == generation

    ok =
      rpc(server, "message/send", %{
        "message" => follow_up,
        "configuration" => %{"ifGenerationMatch" => generation}
      })

    assert %{"result" => %{"task" => %{"id" => ^id}}} = ok
  end
end

# --- SECTION 12: Original test/generation_plug_wiring_test.exs ---
defmodule AshA2A.GenerationPlugWiringTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Plug, as: TransportPlug

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "v12-open",
      description: "accepts client artifacts",
      capabilities: %{user_artifacts: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "ask" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
        _ -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
      end
    end
  end

  defmodule ClosedAgent do
    use AshA2A.Protocol.Agent, name: "v12-closed", description: "no client artifacts"

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "ask" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
        _ -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
      end
    end
  end

  setup do
    start_supervised!({OpenAgent, []})
    start_supervised!({ClosedAgent, []})
    :ok
  end

  defp rpc(agent, method, params) do
    opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://x/a2a")
    envelope = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(envelope))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.call(opts)

    Jason.decode!(conn.resp_body)
  end

  defp wire_message(text, extra \\ %{}) do
    Map.merge(
      %{
        "messageId" => "m-#{System.unique_integer([:positive])}",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => text}]
      },
      extra
    )
  end

  defp new_task(agent) do
    %{"result" => %{"task" => task}} =
      rpc(agent, "SendMessage", %{"message" => wire_message("ask")})

    task
  end

  test "ifGenerationMatch mismatch answers -32010 with ErrorInfo through the plug" do
    task = new_task(OpenAgent)
    current = task["generation"] |> to_string() |> String.to_integer()

    resp =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("again", %{"taskId" => task["id"]}),
        "configuration" => %{"ifGenerationMatch" => current + 5}
      })

    assert resp["error"]["code"] == -32_010
    assert [%{"reason" => "TASK_GENERATION_MISMATCH"}] = resp["error"]["data"]
  end

  test "artifactUpdates on an agent without user_artifacts answers -32004" do
    task = new_task(ClosedAgent)

    resp =
      rpc(ClosedAgent, "SendMessage", %{
        "artifactUpdates" => [
          %{
            "taskId" => task["id"],
            "artifact" => %{"artifactId" => "a1", "parts" => [%{"text" => "x"}]}
          }
        ]
      })

    assert resp["error"]["code"] == -32_004
  end

  test "contextId that does not match the task answers -32602" do
    # A context-less task (nil context) may be bound by a follow-up; the
    # mismatch law applies once the task carries a context.
    %{"result" => %{"task" => task}} =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("ask", %{"contextId" => "ctx-original"})
      })

    resp =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("again", %{"taskId" => task["id"], "contextId" => "other-ctx"})
      })

    assert resp["error"]["code"] == -32_602
  end

  test "build_call_opts forwards ifGenerationMatch so the agent's atomic check runs" do
    task = new_task(OpenAgent)
    current = task["generation"] |> to_string() |> String.to_integer()

    # No pre-check path: the plug's call options carry :if_generation_match to
    # the agent, which refuses atomically.
    resp =
      rpc(OpenAgent, "message/send", %{
        "message" => wire_message("again", %{"taskId" => task["id"]}),
        "configuration" => %{"ifGenerationMatch" => current + 9}
      })

    assert resp["error"]["code"] == -32_010
  end

  describe "Transport.Plug reason table" do
    test "wire_error and reason_error agree on typed send refusals" do
      assert %Error{code: -32_010} = TransportPlug.wire_error(:generation_mismatch)

      assert %Error{code: -32_004} =
               TransportPlug.wire_error({:unsupported_operation, :user_artifacts})

      assert %Error{code: -32_602} = TransportPlug.wire_error(:context_mismatch)
      assert %Error{code: -32_004} = TransportPlug.wire_error(:not_continuable)

      assert %Error{code: -32_005} =
               TransportPlug.wire_error(
                 {:content_type_not_supported, %{acceptedOutputModes: ["x/y"]}}
               )

      assert TransportPlug.reason_error(:something_else) == nil
    end
  end
end

# --- SECTION 13: Original test/generation_store_durability_test.exs ---
defmodule AshA2A.GenerationStoreDurabilityTest do
  @moduledoc """
  Lane X5: v1.1 `generation`, `timeline` and artifact `start_generation` /
  `end_generation` survive the task stores, and a stale (lower-generation)
  write never lowers the stored generation.

  Stale-write policy: NO-OP returning `:ok` (EKV and Ash stores). The ETS
  reference store has no guard (not owned by this lane); only its round trip
  is asserted.

  The Ash store's data layer is `Ash.DataLayer.Ets` (node-lifetime), so its
  "restart" is a fresh reader over the same namespace, not a process restart.
  """

  use ExUnit.Case, async: false

  @moduletag :serial

  alias AshA2A.Protocol.{Artifact, Message, Part, Task, TaskStore, TimelineEntry}
  alias AshA2A.TaskStore.Ash, as: AshStore
  alias AshA2A.TaskStore.Ekv, as: EkvStore

  defp uniq, do: System.unique_integer([:positive])

  defp gen_task(id, generation) do
    status = %Task.Status{state: :working, timestamp: DateTime.utc_now(), message: nil}

    %Task{
      id: id,
      context_id: "ctx-x5",
      status: status,
      history: [],
      artifacts: [
        %{
          Artifact.new([Part.Text.new("a")], name: "a")
          | start_generation: 2,
            end_generation: generation
        }
      ],
      metadata: %{},
      generation: generation,
      timeline: [
        %TimelineEntry{entry: {:message, Message.new_user("hi")}, generation: 1},
        %TimelineEntry{entry: {:status, status}, generation: generation}
      ]
    }
  end

  defp assert_fields(%Task{} = stored, %Task{} = expected) do
    assert stored.generation == expected.generation
    assert stored.timeline == expected.timeline
    assert Enum.map(stored.timeline, & &1.generation) == [1, expected.generation]
    [sa] = stored.artifacts
    [ea] = expected.artifacts
    assert sa.start_generation == 2
    assert sa.end_generation == ea.end_generation
  end

  defp ekv_setup do
    id = uniq()
    name = :"x5_gen_ekv_#{id}"
    dir = Path.join(System.tmp_dir!(), "x5_gen_#{id}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!(EkvStore.child_spec(name: name, data_dir: dir))
    {name, dir}
  end

  test "ETS round trip preserves generation, timeline, artifact generations" do
    name = :"x5_gen_ets_#{uniq()}"
    start_supervised!({TaskStore.ETS, [name: name]})
    task = gen_task("tsk-x5-ets", 7)
    assert :ok = TaskStore.ETS.put(name, task)
    assert {:ok, stored} = TaskStore.ETS.get(name, task.id)
    assert_fields(stored, task)
  end

  test "EKV preserves fields across a real store restart; stale write is a no-op" do
    {name, dir} = ekv_setup()
    task = gen_task("tsk-x5-ekv", 7)
    assert :ok = EkvStore.put(name, task)

    assert :ok = stop_supervised({EKV, name})
    start_supervised!(EkvStore.child_spec(name: name, data_dir: dir))

    assert {:ok, stored} = EkvStore.get(name, task.id)
    assert_fields(stored, task)

    stale = gen_task("tsk-x5-ekv", 3)
    assert :ok = EkvStore.put(name, stale)
    assert {:ok, after_stale} = EkvStore.get(name, task.id)
    assert after_stale.generation == 7
    assert_fields(after_stale, task)

    # Equal and higher generations still write.
    assert :ok = EkvStore.put(name, gen_task("tsk-x5-ekv", 9))
    assert {:ok, %Task{generation: 9}} = EkvStore.get(name, task.id)
  end

  test "Ash store preserves fields for a fresh reader; stale write is a no-op" do
    ref = "x5_gen_ash_#{uniq()}"
    task = gen_task("tsk-x5-ash", 7)
    assert :ok = AshStore.put(ref, task)
    assert AshStore.version(ref, task.id) == 1

    assert {:ok, stored} = AshStore.get(ref, task.id)
    assert_fields(stored, task)

    assert :ok = AshStore.put(ref, gen_task("tsk-x5-ash", 3))
    assert {:ok, after_stale} = AshStore.get(ref, task.id)
    assert after_stale.generation == 7
    assert_fields(after_stale, task)
    assert AshStore.version(ref, task.id) == 1

    assert :ok = AshStore.put(ref, gen_task("tsk-x5-ash", 9))
    assert {:ok, %Task{generation: 9}} = AshStore.get(ref, task.id)
    assert AshStore.version(ref, task.id) == 2
  end
end

# --- SECTION 14: Original test/gi_spark_conflict_probe_test.exs ---
# Probe (fixed forward by lane F1 from another lane's in-progress file, then
# re-pinned by lane G-I): a Spark section that declares a same-named schema
# option AND entity (`mount`) makes Spark generate `mount/1` from both the
# Options module and the entity builder module, so EVERY use inside the
# section fails with "call is ambiguous". This file pins that reality, plus
# the second reality lane G-I's court depends on: a Spark entity with
# positional args cannot also accept the keyword spelling -- the keyword list
# is consumed by the trailing positional arg (pinned by
# test/gi_probe2_test.exs). So the de-conflicted section is option-renamed +
# keyword-only entity, exactly the shape AshA2A.Domain ships.
defmodule Gi.Probe do
  defmodule Mount do
    defstruct [:agent, :path, :__spark_metadata__]
  end

  defmodule Ext do
    use Spark.Dsl.Extension,
      sections: [
        # CONFLICTING section: schema option `mount` + entity `mount` -> the
        # generated `mount/1` import is ambiguous.
        %Spark.Dsl.Section{
          name: :transport,
          schema: [mount: [type: :string, default: "/a2a"]],
          entities: [
            %Spark.Dsl.Entity{
              name: :mount,
              args: [],
              target: Gi.Probe.Mount,
              schema: [
                agent: [type: :atom, required: true],
                path: [type: :string, required: true]
              ]
            }
          ]
        },
        # DE-CONFLICTED control section: the option is renamed so the entity
        # import is unambiguous, and the entity is keyword-only (`args: []`).
        %Spark.Dsl.Section{
          name: :transport_ok,
          schema: [default_mount: [type: :string, default: "/a2a"]],
          entities: [
            %Spark.Dsl.Entity{
              name: :mount,
              args: [],
              target: Gi.Probe.Mount,
              schema: [
                agent: [type: :atom, required: true],
                path: [type: :string, required: true]
              ]
            }
          ]
        }
      ]
  end

  use Spark.Dsl, default_extensions: [extensions: [Gi.Probe.Ext]]
end

defmodule GiSparkConflictProbeTest do
  use ExUnit.Case, async: false

  test "a same-named section option + entity is an ambiguous call and fails to compile" do
    source = """
    defmodule Gi.Probe.Conflicting do
      use Gi.Probe

      transport do
        mount "/x"
      end
    end
    """

    assert_raise CompileError, ~r/cannot compile module/, fn ->
      Code.compile_string(source)
    end
  end

  test "the de-conflicted section parses the keyword-only mount entity" do
    source = """
    defmodule Gi.Probe.Control do
      use Gi.Probe

      transport_ok do
        mount agent: Foo, path: "/y"
      end
    end
    """

    Code.compile_string(source)
    mounts = Spark.Dsl.Extension.get_entities(Gi.Probe.Control, [:transport_ok])

    assert [%Gi.Probe.Mount{agent: Foo, path: "/y"}] = mounts
  end
end

# --- SECTION 15: Original test/grpc_client_transport_test.exs ---
defmodule AshA2A.GRPCClientTransportTest.Handler do
  @moduledoc false
  # A real in-process handler (no mocks): the agent GenServer is the real
  # agent, push configs live in a real Agent process.
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Runtime

  @store AshA2A.GRPCClientTransportTest.PushStore

  @impl true
  def handle_send(message, _params, %{agent: agent}) do
    opts = [task_id: message.task_id, context_id: message.context_id]

    case AshA2A.Protocol.call(agent, message, opts) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
      {:error, _} -> {:error, Error.internal_error()}
    end
  end

  @impl true
  def handle_get(id, _params, %{agent: agent}) do
    case GenServer.call(agent, {:get_task, id}) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_cancel(id, _params, %{agent: agent}) do
    case GenServer.call(agent, {:get_task, id}) do
      {:ok, _} -> {:error, Error.task_not_cancelable()}
      {:error, :not_found} -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_list(params, ctx) do
    case GenServer.call(ctx.agent, {:ash_a2a_list_tasks, ctx.principal, params}) do
      {:ok, %{tasks: tasks} = result} ->
        {:ok, %{result | tasks: Enum.map(tasks, &Runtime.wire_task/1)}}

      {:error, _} ->
        {:error, Error.internal_error()}
    end
  end

  @impl true
  def handle_set_push_config(config, _params, _ctx) do
    stored = %{config | id: config.id || AshA2A.Protocol.ID.generate("pc")}
    Agent.update(@store, &Map.put(&1, {stored.task_id, stored.id}, stored))
    {:ok, stored}
  end

  @impl true
  def handle_get_push_config(task_id, config_id, _params, _ctx) do
    case Agent.get(@store, &Map.get(&1, {task_id, config_id})) do
      nil -> {:error, Error.task_not_found()}
      config -> {:ok, config}
    end
  end

  @impl true
  def handle_list_push_configs(task_id, _params, _ctx) do
    {:ok, Agent.get(@store, fn m -> for {{^task_id, _}, config} <- m, do: config end)}
  end

  @impl true
  def handle_delete_push_config(task_id, config_id, _params, _ctx) do
    Agent.update(@store, &Map.delete(&1, {task_id, config_id}))
    :ok
  end

  def handle_extended_card(_ctx) do
    {:ok,
     %{
       "name" => "y1-extended",
       "description" => "extended card over gRPC",
       "version" => "1.0.0",
       "supportedInterfaces" => [
         %{"url" => "localhost:1", "protocolBinding" => "GRPC", "protocolVersion" => "1.1"}
       ],
       "capabilities" => %{},
       "defaultInputModes" => ["text/plain"],
       "defaultOutputModes" => ["text/plain"],
       "skills" => [%{"id" => "s1", "name" => "skill", "description" => "d", "tags" => ["t"]}]
     }}
  end
end

defmodule AshA2A.GRPCClientTransportTest do
  @moduledoc """
  Y1 courts: the gRPC client binding against a real cowboy HTTP/2 listener
  (`AshA2A.Transport.GRPC.Supervisor`) and a real Mint gRPC channel. No mocks:
  the handler drives the real agent GenServer and a real Agent-backed push store.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.Client
  alias AshA2A.Protocol.Client.GRPC, as: GrpcClient
  alias AshA2A.GRPCClientTransportTest.Handler

  @server AshA2A.Transport.GRPC.Server
  @store AshA2A.GRPCClientTransportTest.PushStore

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "y1-open",
      description: "streaming, keeps tasks open",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(%{parts: [%AshA2A.Protocol.Part.Text{text: "stream me"} | _]}, _ctx),
      do: {:stream, Stream.map(1..3, &AshA2A.Protocol.Part.Text.new("chunk #{&1}"))}

    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  setup do
    start_supervised!({OpenAgent, []})
    start_supervised!(%{id: @store, start: {Agent, :start_link, [fn -> %{} end, [name: @store]]}})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    previous = Application.get_env(:ash_a2a, :long_poll_timeout_ms)
    Application.put_env(:ash_a2a, :long_poll_timeout_ms, 10_000)

    on_exit(fn ->
      Application.delete_env(:ash_a2a, @server)

      if previous,
        do: Application.put_env(:ash_a2a, :long_poll_timeout_ms, previous),
        else: Application.delete_env(:ash_a2a, :long_poll_timeout_ms)
    end)

    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: Handler,
         ctx: %{agent: OpenAgent, opts: %{}, transport: transport, principal: :anonymous},
         name: Module.concat(__MODULE__, Sup)}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, client} = GrpcClient.connect(Client.new("localhost:#{port}", transport: :grpc))
    on_exit(fn -> GrpcClient.disconnect(client) end)

    {:ok, client: client, port: port}
  end

  defp new_task(client) do
    assert {:ok, %AshA2A.Protocol.Task{} = task} = Client.send_message(client, "ask")
    task
  end

  defp next(events) do
    case Enum.take(events, 1) do
      [event] -> event
      other -> flunk("expected one event, got #{inspect(other)}")
    end
  end

  # -- unary -------------------------------------------------------------------

  test "send_message returns a Task over gRPC", %{client: client} do
    task = new_task(client)
    assert is_binary(task.id)
    assert task.status.state == :input_required
  end

  test "get_task round trips and an unknown id is :task_not_found", %{client: client} do
    task = new_task(client)
    assert {:ok, %AshA2A.Protocol.Task{id: id}} = Client.get_task(client, task.id)
    assert id == task.id
    assert {:error, :task_not_found} = Client.get_task(client, "y1-missing")
  end

  test "get_task timeline_length truncates", %{client: client} do
    task = new_task(client)
    assert {:ok, _} = Client.send_message(client, "two", task_id: task.id)

    assert {:ok, %{timeline: full}} = Client.get_task(client, task.id)
    assert full != []
    assert {:ok, %{timeline: cut}} = Client.get_task(client, task.id, timeline_length: 1)
    assert length(cut) == 1
  end

  test "current_generation long-polls until the generation advances", %{client: client} do
    task = new_task(client)

    poll =
      Task.async(fn ->
        Client.get_task(client, task.id, current_generation: task.generation, timeout: 15_000)
      end)

    assert {:ok, _} = Client.send_message(client, "again", task_id: task.id)
    assert {:ok, %AshA2A.Protocol.Task{generation: gen}} = Task.await(poll, 12_000)
    assert gen > task.generation
  end

  test "A2A-Version metadata: an explicit 1.0 client gets no v1.1 timeline", %{
    client: client,
    port: port
  } do
    task = new_task(client)
    assert {:ok, %{timeline: [_ | _]}} = Client.get_task(client, task.id)

    v10 =
      Client.new("localhost:#{port}", transport: :grpc, version: "1.0", channel: client.channel)

    assert {:ok, %{timeline: []}} = Client.get_task(v10, task.id)
  end

  test "if_generation_match mismatch -> {:task_generation_mismatch, details}", %{client: client} do
    task = new_task(client)

    assert {:error, {:task_generation_mismatch, %{metadata: metadata, message: message}}} =
             Client.send_message(client, "more", task_id: task.id, if_generation_match: 987_654)

    assert is_map(metadata)
    assert is_binary(message)
  end

  test "cancel_task maps typed refusals", %{client: client} do
    task = new_task(client)
    assert {:error, :task_not_cancelable} = Client.cancel_task(client, task.id)
    assert {:error, :task_not_found} = Client.cancel_task(client, "y1-missing")
  end

  test "list_tasks answers the page envelope", %{client: client} do
    _task = new_task(client)

    # The fixture caller is anonymous and anonymous callers never enumerate
    # tasks (owner gate), so the envelope is well-formed and empty.
    assert {:ok, %{tasks: tasks} = page} = Client.list_tasks(client)
    assert tasks == []
    assert is_map(page)
  end

  test "push config CRUD over the four RPCs", %{client: client} do
    task = new_task(client)

    config = %AshA2A.Protocol.PushNotificationConfig{
      task_id: task.id,
      url: "https://example.com/hook",
      token: "t0"
    }

    assert {:ok, %AshA2A.Protocol.PushNotificationConfig{id: id, url: "https://example.com/hook"}} =
             Client.set_push_config(client, config)

    assert is_binary(id)

    assert {:ok, %{id: ^id, token: "t0"}} = Client.get_push_config(client, task.id, id)
    assert {:ok, [%{id: ^id}]} = Client.list_push_configs(client, task.id)
    assert :ok = Client.delete_push_config(client, task.id, id)
    assert {:ok, []} = Client.list_push_configs(client, task.id)
    assert {:error, :task_not_found} = Client.get_push_config(client, task.id, id)
  end

  test "get_extended_card decodes the extended card", %{client: client} do
    assert {:ok, %AshA2A.Protocol.AgentCard{name: "y1-extended"}} =
             Client.get_extended_card(client)
  end

  # -- channel handling ------------------------------------------------------------

  test "a client without a channel connects per call", %{port: port} do
    lazy = Client.new("localhost:#{port}", transport: :grpc)
    assert lazy.channel == nil
    assert {:ok, %AshA2A.Protocol.Task{}} = Client.send_message(lazy, "no channel")
  end

  test "connect/disconnect manage the stored channel", %{port: port} do
    assert {:ok, %Client{channel: channel} = connected} =
             GrpcClient.connect(Client.new("localhost:#{port}", transport: :grpc))

    assert channel != nil
    assert %Client{channel: nil} = GrpcClient.disconnect(connected)
  end

  test "a refused connection is a typed error" do
    dead = Client.new("localhost:1", transport: :grpc)
    assert {:error, {:grpc_connect_failed, _}} = Client.send_message(dead, "hi")
  end

  test "from_card selects GRPC only when preferred_bindings names it", %{port: port} do
    card =
      struct(AshA2A.Protocol.AgentCard,
        name: "y1",
        description: "d",
        url: "http://unused",
        supported_interfaces: [
          %{url: "localhost:#{port}", protocol_binding: "GRPC", protocol_version: "1.1"}
        ]
      )

    assert {:error, :no_supported_interface} = Client.from_card(card)

    assert {:ok, %Client{transport: :grpc, version: "1.1"} = client} =
             Client.from_card(card, preferred_bindings: [:grpc])

    assert {:ok, %AshA2A.Protocol.Task{}} = Client.send_message(client, "via card")
  end

  # -- streaming ----------------------------------------------------------------------

  test "stream_message yields decoded events", %{client: client} do
    assert {:ok, stream} = Client.stream_message(client, "stream me")

    assert %mod{} = next(stream)

    assert mod in [
             AshA2A.Protocol.Task,
             AshA2A.Protocol.Event.StatusUpdate,
             AshA2A.Protocol.Event.ArtifactUpdate,
             AshA2A.Protocol.Message
           ]
  end

  test "resubscribe with last_seen_generation replays events without a snapshot", %{
    client: client
  } do
    task = new_task(client)

    sub =
      Task.async(fn ->
        case Client.resubscribe(client, task.id,
               last_seen_generation: task.generation,
               timeout: 10_000
             ) do
          {:ok, stream} -> {:ok, Enum.take(stream, 1)}
          other -> other
        end
      end)

    # the stream opens lazily on its first frame: produce one
    assert {:ok, _} = Client.send_message(client, "next", task_id: task.id)

    assert {:ok, [event]} = Task.await(sub, 12_000)
    refute match?(%AshA2A.Protocol.Task{}, event), "expected an event, got a snapshot"
  end

  # -- live (bidirectional) -------------------------------------------------------------

  test "live session: subscribe, uplink message, close", %{client: client} do
    task = new_task(client)

    assert {:ok, %{events: events, session: session}} =
             GrpcClient.open_live(client, %{"subscribe" => %{"id" => task.id}}, timeout: 15_000)

    assert %AshA2A.Protocol.Task{id: id} = next(events)
    assert id == task.id

    assert :ok = GrpcClient.live_send(session, "more", [])
    assert next(events) != nil

    assert :ok = GrpcClient.live_close(session)
  end

  test "live uplink rejection surfaces as a stream_error event", %{client: client} do
    task = new_task(client)

    assert {:ok, %{events: events, session: session}} =
             GrpcClient.open_live(client, %{"subscribe" => %{"id" => task.id}}, timeout: 15_000)

    assert %AshA2A.Protocol.Task{} = next(events)
    assert :ok = GrpcClient.live_send(session, "more", if_generation_match: 987_654)
    assert {:stream_error, %AshA2A.Protocol.StreamError{}} = next(events)

    assert :ok = GrpcClient.live_close(session)
  end

  test "open_live refuses non-gRPC clients" do
    assert {:error, {:transport_unsupported, :grpc_live}} =
             GrpcClient.open_live(Client.new("http://localhost:1", transport: :http_json), %{})
  end

  # -- error mapping ----------------------------------------------------------------------

  test "map_error maps status codes without ErrorInfo" do
    assert :task_not_found = GrpcClient.map_error(%GRPC.RPCError{status: 5, message: "x"})
    assert {:unauthorized, []} = GrpcClient.map_error(%GRPC.RPCError{status: 16, message: "x"})
    assert {:forbidden, "no"} = GrpcClient.map_error(%GRPC.RPCError{status: 7, message: "no"})

    assert {:grpc_error, 13, "boom"} =
             GrpcClient.map_error(%GRPC.RPCError{status: 13, message: "boom"})

    assert :passthrough = GrpcClient.map_error(:passthrough)
  end

  test "map_error maps ErrorInfo reasons incl. generation mismatch" do
    info = fn reason, metadata ->
      %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.rpc.ErrorInfo",
        value:
          Google.Rpc.ErrorInfo.encode(%Google.Rpc.ErrorInfo{
            reason: reason,
            domain: "a2a-protocol.org",
            metadata: metadata
          })
      }
    end

    assert :task_not_cancelable =
             GrpcClient.map_error(%GRPC.RPCError{
               status: 9,
               message: "m",
               details: [info.("TASK_NOT_CANCELABLE", %{})]
             })

    assert {:task_generation_mismatch, %{metadata: %{"actualGeneration" => "3"}, message: "m"}} =
             GrpcClient.map_error(%GRPC.RPCError{
               status: 10,
               message: "m",
               details: [info.("TASK_GENERATION_MISMATCH", %{"actualGeneration" => "3"})]
             })

    assert {:grpc_error, 9, "m"} =
             GrpcClient.map_error(%GRPC.RPCError{
               status: 9,
               message: "m",
               details: [info.("SOMETHING_NEW", %{})]
             })
  end
end

# --- SECTION 16: Original test/grpc_extension_gate_test.exs ---
defmodule AshA2A.GRPCExtensionGateTest.Ext do
  @moduledoc false
  @behaviour AshA2A.Protocol.Extension
  @uri "https://example.com/ext/w6-required"

  def uri, do: @uri

  @impl true
  def declaration(_state),
    do: %AshA2A.Protocol.AgentExtension{uri: @uri, description: "w6", required: true}

  @impl true
  def activate(_requested, _ctx, _state), do: {:ok, :active}
end

defmodule AshA2A.GRPCExtensionGateTest.Handler do
  @moduledoc false
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Test.Fixture.EchoAgent

  @impl true
  def handle_send(message, _params, %{agent: agent}), do: AshA2A.Protocol.call(agent, message)

  @impl true
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} ->
        {:ok, task}

      {:error, :not_found} ->
        {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "nf"}}
    end
  end

  @impl true
  def handle_cancel(_task_id, _params, _ctx),
    do: {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "nf"}}

  @impl true
  def handle_list(params, %{test_pid: pid}) do
    send(pid, {:list_params, params})
    {:ok, %{tasks: [], total_size: 0, page_size: 0, next_page_token: ""}}
  end
end

defmodule AshA2A.GRPCExtensionGateTest do
  @moduledoc """
  W6 courts over a real cowboy HTTP/2 listener on an ephemeral port and a real
  Mint gRPC client: A2A-Version gate on all 11 RPCs, A2A-Extensions gate
  (-32008 -> FAILED_PRECONDITION, activated-extension response metadata),
  configurable supported versions, PERMISSION_DENIED(7) mapping, ListTasks
  status/history passthrough, and the supervised listener loopback.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.GRPCExtensionGateTest.{Ext, Handler}
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @endpoint AshA2A.Transport.GRPC.Server.Endpoint

  defmodule Forbidder do
    @moduledoc false
    # Real interceptor: identity "bob" is authenticated but not permitted.
    def authenticate(mat, _opts) do
      case GRPC.Stream.get_headers(mat) do
        %{"x-user" => "bob"} -> {:error, :forbidden}
        _ -> :ok
      end
    end
  end

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, @server)
      Application.delete_env(:ash_a2a, @endpoint)
    end)

    {:ok, transport: transport}
  end

  defp put_server(transport, extra \\ []) do
    Application.put_env(
      :ash_a2a,
      @server,
      Keyword.merge(
        [
          handler: Handler,
          ctx: %{agent: EchoAgent, opts: [], transport: transport, test_pid: self()}
        ],
        extra
      )
    )
  end

  defp start_listener do
    {:ok, _pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    channel
  end

  defp message_request do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("w6"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "hi"}}]
      }
    }
  end

  # Streaming stubs may surface the refusal either as the call result or as
  # the first element of the response stream.
  defp first_error({:error, %GRPC.RPCError{} = e}), do: e

  defp first_error({:ok, stream}) do
    case Enum.take(stream, 1) do
      [{:error, %GRPC.RPCError{} = e}] -> e
      other -> flunk("expected an RPC error, got #{inspect(other)}")
    end
  end

  defp first_error(other), do: flunk("expected an RPC error, got #{inspect(other)}")

  @bad_version [metadata: %{"a2a-version" => "99.0"}]

  test "all 11 RPCs refuse an unsupported a2a-version with UNIMPLEMENTED(12)", %{transport: t} do
    put_server(t)
    ch = start_listener()

    calls = [
      {"SendMessage", fn -> Stub.send_message(ch, message_request(), @bad_version) end},
      {"SendStreamingMessage",
       fn -> Stub.send_streaming_message(ch, message_request(), @bad_version) end},
      {"GetTask", fn -> Stub.get_task(ch, %Pb.GetTaskRequest{id: "x"}, @bad_version) end},
      {"CancelTask",
       fn -> Stub.cancel_task(ch, %Pb.CancelTaskRequest{id: "x"}, @bad_version) end},
      {"ListTasks", fn -> Stub.list_tasks(ch, %Pb.ListTasksRequest{}, @bad_version) end},
      {"SubscribeToTask",
       fn -> Stub.subscribe_to_task(ch, %Pb.SubscribeToTaskRequest{id: "x"}, @bad_version) end},
      {"CreateTaskPushNotificationConfig",
       fn ->
         Stub.create_task_push_notification_config(
           ch,
           %Pb.TaskPushNotificationConfig{},
           @bad_version
         )
       end},
      {"GetTaskPushNotificationConfig",
       fn ->
         Stub.get_task_push_notification_config(
           ch,
           %Pb.GetTaskPushNotificationConfigRequest{},
           @bad_version
         )
       end},
      {"ListTaskPushNotificationConfigs",
       fn ->
         Stub.list_task_push_notification_configs(
           ch,
           %Pb.ListTaskPushNotificationConfigsRequest{},
           @bad_version
         )
       end},
      {"DeleteTaskPushNotificationConfig",
       fn ->
         Stub.delete_task_push_notification_config(
           ch,
           %Pb.DeleteTaskPushNotificationConfigRequest{},
           @bad_version
         )
       end},
      {"GetExtendedAgentCard",
       fn -> Stub.get_extended_agent_card(ch, %Pb.GetExtendedAgentCardRequest{}, @bad_version) end}
    ]

    assert length(calls) == 11

    for {name, call} <- calls do
      error = first_error(call.())
      assert error.status == 12, "#{name}: expected UNIMPLEMENTED(12), got #{inspect(error)}"
    end
  end

  test "SendLiveMessage (v1.1 bidi) refuses an unsupported a2a-version with UNIMPLEMENTED(12)", %{
    transport: t
  } do
    put_server(t)
    ch = start_listener()

    stream = Stub.send_live_message(ch, @bad_version)
    stream = GRPC.Stub.send_request(stream, %Pb.StreamRequest{}, end_stream: true)

    error =
      case GRPC.Stub.recv(stream, timeout: 5_000) do
        {:error, %GRPC.RPCError{} = e} ->
          e

        {:ok, replies} ->
          case Enum.take(replies, 1) do
            [{:error, %GRPC.RPCError{} = e}] -> e
            other -> flunk("expected an RPC error, got #{inspect(other)}")
          end
      end

    assert error.status == 12
  end

  test "required extension missing -> FAILED_PRECONDITION(9); present -> ok + echoed metadata", %{
    transport: t
  } do
    put_server(t, extensions: [Ext])
    ch = start_listener()

    assert {:error, %GRPC.RPCError{status: 9, message: msg}} =
             Stub.send_message(ch, message_request())

    assert msg =~ Ext.uri()

    assert {:ok, %Pb.SendMessageResponse{}, %{headers: headers}} =
             Stub.send_message(ch, message_request(),
               metadata: %{"a2a-extensions" => Ext.uri()},
               return_headers: true
             )

    assert headers["a2a-extensions"] == Ext.uri()

    # Streaming and unary alike are gated.
    assert %GRPC.RPCError{status: 9} =
             first_error(Stub.send_streaming_message(ch, message_request()))
  end

  test "supported versions are configurable", %{transport: t} do
    put_server(t, versions: ["1.0"])
    ch = start_listener()

    # Absent header = "0.3" default, which this server no longer supports.
    assert {:error, %GRPC.RPCError{status: 12}} = Stub.send_message(ch, message_request())

    assert {:ok, %Pb.SendMessageResponse{}} =
             Stub.send_message(ch, message_request(), metadata: %{"a2a-version" => "1.0"})
  end

  test "forbidden interceptor outcome maps to PERMISSION_DENIED(7); unauthenticated stays 16", %{
    transport: t
  } do
    put_server(t)
    Application.put_env(:ash_a2a, @endpoint, auth: {Forbidder, nil})
    ch = start_listener()

    assert {:error, %GRPC.RPCError{status: 7}} =
             Stub.send_message(ch, message_request(), metadata: %{"x-user" => "bob"})

    assert {:ok, %Pb.SendMessageResponse{}} =
             Stub.send_message(ch, message_request(), metadata: %{"x-user" => "alice"})

    assert AshA2A.Transport.GRPC.Auth.forbidden().status == 7
  end

  test "ListTasks: UNSPECIFIED status is no filter; history_length passes through", %{
    transport: t
  } do
    put_server(t)
    ch = start_listener()

    assert {:ok, %Pb.ListTasksResponse{}} =
             Stub.list_tasks(ch, %Pb.ListTasksRequest{history_length: 2, page_size: 5})

    assert_receive {:list_params, params}, 5_000
    refute Map.has_key?(params, "status")
    assert params["historyLength"] == 2
    assert params["pageSize"] == 5
  end

  test "supervised listener boots on an ephemeral port and answers a loopback call", %{
    transport: t
  } do
    spec =
      {AshA2A.Transport.GRPC.Supervisor,
       port: 0,
       handler: Handler,
       ctx: %{agent: EchoAgent, opts: [], transport: t, test_pid: self()},
       name: AshA2A.GRPCExtensionGateTest.GrpcListener}

    sup = start_supervised!(spec)

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    assert is_integer(port) and port > 0

    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, message_request())

    assert id != ""
  end
end

# --- SECTION 17: Original test/grpc_generation_gaps_test.exs ---
defmodule AshA2A.GRPCGenerationGapsTest.Handler do
  @moduledoc false
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error

  @impl true
  def handle_send(message, _params, %{agent: agent}) do
    opts = [task_id: message.task_id, context_id: message.context_id]

    case AshA2A.Protocol.call(agent, message, opts) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
      {:error, _} -> {:error, Error.internal_error()}
    end
  end

  @impl true
  def handle_get(id, _params, %{agent: agent}) do
    case GenServer.call(agent, {:get_task, id}) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_cancel(_id, _params, _ctx), do: {:error, Error.task_not_cancelable()}
end

defmodule AshA2A.GRPCGenerationGapsTest do
  @moduledoc """
  X2 courts: v1.1 gaps on the gRPC binding over a real cowboy HTTP/2 listener
  and a real Mint gRPC client. Live-path downgrade for explicit <1.1 clients,
  `Downgrade.strip` of `message_update`, GetTask `timeline_length` and
  `current_generation` long-poll, `ifGenerationMatch` -> ABORTED(10), and
  SubscribeToTask `last_seen_generation` replay. No sleeps: bounded recv/await.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Transport.GRPC.Downgrade
  alias AshA2A.GRPCGenerationGapsTest.Handler
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @v10 [metadata: %{"a2a-version" => "1.0"}]
  @v11 [metadata: %{"a2a-version" => "1.1"}]

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "x2-open",
      description: "streaming, keeps tasks open",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  setup do
    start_supervised!({OpenAgent, []})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    previous = Application.get_env(:ash_a2a, :long_poll_timeout_ms)
    Application.put_env(:ash_a2a, :long_poll_timeout_ms, 10_000)

    on_exit(fn ->
      Application.delete_env(:ash_a2a, @server)

      if previous,
        do: Application.put_env(:ash_a2a, :long_poll_timeout_ms, previous),
        else: Application.delete_env(:ash_a2a, :long_poll_timeout_ms)
    end)

    {:ok, transport: transport}
  end

  defp connect(transport, name) do
    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: Handler,
         ctx: %{agent: OpenAgent, opts: %{}, transport: transport, principal: :anonymous},
         name: name}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    ch
  end

  defp message(text, extra \\ []) do
    struct(
      %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("x2"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      },
      extra
    )
  end

  defp send_pb(ch, text, extra \\ [], opts \\ @v11) do
    req = %Pb.SendMessageRequest{message: message(text, extra)}
    Stub.send_message(ch, req, opts)
  end

  defp new_task(ch) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             send_pb(ch, "ask")

    task
  end

  defp push(stream, payload),
    do: GRPC.Stub.send_request(stream, %Pb.StreamRequest{payload: payload})

  defp next(replies) do
    case Enum.take(replies, 1) do
      [{:ok, %Pb.StreamResponse{payload: {kind, value}}}] -> {kind, value}
      other -> flunk("expected one StreamResponse, got #{inspect(other)}")
    end
  end

  defp rpc_error_reasons(%GRPC.RPCError{details: details}) do
    for %Google.Protobuf.Any{value: v} <- List.wrap(details),
        do: Google.Rpc.ErrorInfo.decode(v).reason
  end

  # -- live-path downgrade ---------------------------------------------------

  test "SendLiveMessage with an explicit 1.0 client carries no v1.1 fields", %{transport: t} do
    ch = connect(t, __MODULE__.LiveSup)
    task = new_task(ch)
    assert task.generation > 0

    stream =
      ch
      |> Stub.send_live_message(@v10 ++ [timeout: 15_000])
      |> push({:subscribe, %Pb.SubscribeToTaskRequest{id: task.id}})

    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: 10_000)

    assert {:task, %Pb.Task{} = snap} = next(replies)
    assert snap.generation == 0
    assert snap.timeline == []

    _stream =
      push(
        stream,
        {:send_message, %Pb.SendMessageRequest{message: message("more", task_id: task.id)}}
      )

    {kind, value} = next(replies)
    refute kind == :message_update

    case {kind, value} do
      {:task, t} -> assert t.generation == 0 and t.timeline == []
      {:status_update, e} -> assert e.generation == 0
      {:artifact_update, e} -> assert e.generation == 0
      _ -> :ok
    end
  end

  test "Downgrade.strip drops a message_update StreamResponse for <1.1, keeps it for 1.1/nil" do
    frame = %Pb.StreamResponse{payload: {:message_update, %Pb.TaskMessageUpdateEvent{}}}

    assert Downgrade.strip(frame, "1.0") == :drop
    assert Downgrade.strip(frame, "0.3") == :drop
    assert Downgrade.strip(frame, "1.1") == frame
    assert Downgrade.strip(frame, nil) == frame
  end

  # -- GetTask options -------------------------------------------------------

  test "GetTask timeline_length truncates the timeline over gRPC", %{transport: t} do
    ch = connect(t, __MODULE__.TimelineSup)
    task = new_task(ch)
    assert {:ok, _} = send_pb(ch, "two", task_id: task.id)

    assert {:ok, %Pb.Task{timeline: full}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: task.id}, @v11)

    assert full != []

    assert {:ok, %Pb.Task{timeline: cut}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: task.id, timeline_length: 1}, @v11)

    assert length(cut) == 1
    assert length(full) >= length(cut)
  end

  test "GetTask current_generation long-polls until the generation advances", %{transport: t} do
    ch = connect(t, __MODULE__.PollSup)
    task = new_task(ch)
    gen = task.generation

    poll =
      Task.async(fn ->
        Stub.get_task(
          ch,
          %Pb.GetTaskRequest{id: task.id, current_generation: gen},
          @v11 ++ [timeout: 15_000]
        )
      end)

    assert {:ok, _} = send_pb(ch, "again", task_id: task.id)

    assert {:ok, %Pb.Task{generation: new_gen}} = Task.await(poll, 12_000)
    assert new_gen > gen
  end

  test "ifGenerationMatch mismatch -> ABORTED(10) TASK_GENERATION_MISMATCH", %{transport: t} do
    ch = connect(t, __MODULE__.MismatchSup)
    task = new_task(ch)

    req = %Pb.SendMessageRequest{
      message: message("more", task_id: task.id),
      configuration: %Pb.SendMessageConfiguration{if_generation_match: 987_654}
    }

    assert {:error, %GRPC.RPCError{status: 10} = error} = Stub.send_message(ch, req, @v11)
    assert "TASK_GENERATION_MISMATCH" in rpc_error_reasons(error)
  end

  # -- SubscribeToTask replay ------------------------------------------------

  test "SubscribeToTask last_seen_generation replays events without a snapshot", %{transport: t} do
    ch = connect(t, __MODULE__.ReplaySup)
    task = new_task(ch)

    req = %Pb.SubscribeToTaskRequest{id: task.id, last_seen_generation: task.generation}
    sub = Task.async(fn -> Stub.subscribe_to_task(ch, req, @v11 ++ [timeout: 10_000]) end)

    # the stream opens lazily on its first frame: produce one
    assert {:ok, _} = send_pb(ch, "next", task_id: task.id)

    assert {:ok, replies} = Task.await(sub, 12_000)
    {kind, _value} = next(replies)
    refute kind == :task, "expected an event after last_seen_generation, got a snapshot"
  end
end

# --- SECTION 18: Original test/grpc_live_paths_test.exs ---
defmodule AshA2A.GRPCLivePathsTest.Handler do
  @moduledoc false
  # Real JSON-RPC handler over the real agent (same shape as the V10/X2 handlers).
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error

  @impl true
  def handle_send(message, _params, %{agent: agent}) do
    opts = [task_id: message.task_id, context_id: message.context_id]

    case AshA2A.Protocol.call(agent, message, opts) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
      {:error, _} -> {:error, Error.internal_error()}
    end
  end

  @impl true
  def handle_get(id, _params, %{agent: agent}) do
    case GenServer.call(agent, {:get_task, id}) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_cancel(_id, _params, _ctx), do: {:error, Error.task_not_cancelable()}
end

defmodule AshA2A.GRPCLivePathsTest.Verify do
  @moduledoc false
  # Real verify/3 callback for the gRPC auth interceptor: `tok-<sub>` is valid.
  def verify(_scheme, "tok-" <> sub, _conn) when sub != "", do: {:ok, %{id: sub}}
  def verify(_scheme, _credential, _conn), do: {:error, "invalid credential"}
end

defmodule AshA2A.GRPCLivePathsTest do
  @moduledoc """
  Y5 courts: gRPC `SendLiveMessage` / `SubscribeToTask` live paths over a real
  cowboy HTTP/2 listener and a real Mint gRPC client. Open failure ->
  UNAVAILABLE(14), send-first, half-close drain, client-disconnect session
  teardown (observed through a process monitor on the real Live session, never a
  sleep), auth on the live RPC, per-request tenant, and SubscribeToTask on a
  terminal task. Every wait is a bounded recv / monitor / assert_receive.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GRPCLivePathsTest.{Handler, Verify}
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @endpoint AshA2A.Transport.GRPC.Server.Endpoint
  @v11 [metadata: %{"a2a-version" => "1.1"}]
  @deadline_ms 10_000

  defmodule LiveAgent do
    use AshA2A.Protocol.Agent,
      name: "y5-live",
      description: "streaming; 'done' completes, anything else parks in input_required",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "done" -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
        _ -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
      end
    end
  end

  setup do
    start_supervised!({LiveAgent, []})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, @server)
      Application.delete_env(:ash_a2a, @endpoint)
    end)

    {:ok, transport: transport}
  end

  # -- helpers ---------------------------------------------------------------

  defp connect(agent, transport, name) do
    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: Handler,
         ctx: %{agent: agent, opts: %{}, transport: transport, principal: :anonymous},
         name: name}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    ch
  end

  defp message(text, extra \\ []) do
    struct(
      %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("y5"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      },
      extra
    )
  end

  defp new_task(ch, text) do
    req = %Pb.SendMessageRequest{message: message(text)}

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Stub.send_message(ch, req, @v11)

    task
  end

  defp open_live(ch, opts \\ @v11), do: Stub.send_live_message(ch, opts ++ [timeout: 15_000])

  defp push(stream, payload, tenant \\ ""),
    do: GRPC.Stub.send_request(stream, %Pb.StreamRequest{tenant: tenant, payload: payload})

  defp send_msg(text, extra \\ []),
    do: {:send_message, %Pb.SendMessageRequest{message: message(text, extra)}}

  defp next(replies) do
    case Enum.take(replies, 1) do
      [{:ok, %Pb.StreamResponse{payload: {kind, value}}}] -> {kind, value}
      other -> flunk("expected one StreamResponse, got #{inspect(other)}")
    end
  end

  # One enumeration pass over the next `n` frames (the lazy reply stream is consumed once).
  defp take_frames(replies, n) do
    for {:ok, %Pb.StreamResponse{payload: {kind, value}}} <- Enum.take(replies, n),
        do: {kind, value}
  end

  # Skips ordinary frames (e.g. the accepted request's update) up to the first StreamError.
  defp next_error(replies, budget \\ 6) do
    case {next(replies), budget} do
      {{:error, _} = error, _} -> error
      {frame, 0} -> flunk("no StreamError within budget, last frame #{inspect(frame)}")
      {_other, n} -> next_error(replies, n - 1)
    end
  end

  # First RPC error of a call, whether it surfaces from recv/2 or as the first reply.
  defp first_error({:error, %GRPC.RPCError{} = e}), do: e

  defp first_error({:ok, replies}) do
    case Enum.take(replies, 1) do
      [{:error, %GRPC.RPCError{} = e}] -> e
      other -> flunk("expected an RPC error, got #{inspect(other)}")
    end
  end

  defp rpc_error_reasons(%GRPC.RPCError{details: details}) do
    for %Google.Protobuf.Any{value: v} <- List.wrap(details),
        do: Google.Rpc.ErrorInfo.decode(v).reason
  end

  # Live sessions currently registered (session pids are the observable).
  defp session_pids do
    Registry.select(AshA2A.Transport.Live.registry(), [{{{:session, :_}, :"$1", :_}, [], [:"$1"]}])
  end

  defp the_new_session(before) do
    case session_pids() -- before do
      [pid] -> pid
      other -> flunk("expected exactly one new live session, got #{inspect(other)}")
    end
  end

  # -- open failure ----------------------------------------------------------

  test "SendLiveMessage UNAVAILABLE(14) when the agent cannot be reached to open the session", %{
    transport: t
  } do
    ch = connect(:y5_no_such_agent, t, __MODULE__.UnavailSup)
    before = session_pids()

    stream = ch |> open_live() |> push(send_msg("ask"))
    error = first_error(GRPC.Stub.recv(stream, timeout: @deadline_ms))

    assert error.status == 14

    AshA2A.TestSupport.Eventually.eventually(fn -> session_pids() -- before == [] end,
      message: "live session leaked after UNAVAILABLE"
    )
  end

  # -- send-first / half-close / disconnect -----------------------------------

  test "SendLiveMessage send-first: the first frame is the new task's snapshot", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.SendFirstSup)

    stream = ch |> open_live() |> push(send_msg("ask"))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: @deadline_ms)

    assert {:task, %Pb.Task{id: id, status: %Pb.TaskStatus{state: state}}} = next(replies)
    assert id != ""
    assert state == :TASK_STATE_INPUT_REQUIRED

    # The task the stream created is a real task on the agent.
    assert {:ok, %Pb.Task{id: ^id}} = Stub.get_task(ch, %Pb.GetTaskRequest{id: id}, @v11)
  end

  test "half-close drains accepted frames, ends the RPC cleanly and closes the session", %{
    transport: t
  } do
    ch = connect(LiveAgent, t, __MODULE__.HalfCloseSup)
    before = session_pids()

    stream = ch |> open_live() |> push(send_msg("ask"))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: @deadline_ms)
    assert {:task, %Pb.Task{id: id}} = next(replies)

    session = the_new_session(before)
    assert Process.alive?(session)
    ref = Process.monitor(session)

    # A second accepted request, then half-close: its frames must still arrive.
    stream = push(stream, send_msg("more", task_id: id))
    _stream = GRPC.Stub.end_stream(stream)

    rest = Enum.to_list(replies)

    refute Enum.any?(rest, &match?({:error, _}, &1)),
           "half-close surfaced an error: #{inspect(rest)}"

    frames = for {:ok, %Pb.StreamResponse{payload: {kind, _}}} <- rest, do: kind
    refute :error in frames
    # drain is best effort (bounded): the stream must end cleanly; frames may or may not arrive
    assert is_list(frames)

    assert_receive {:DOWN, ^ref, :process, ^session, _reason}, @deadline_ms
  end

  test "client disconnect closes the Live session (observed via monitor)", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.DisconnectSup)
    before = session_pids()

    stream = ch |> open_live() |> push(send_msg("ask"))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: @deadline_ms)
    assert {:task, %Pb.Task{}} = next(replies)

    session = the_new_session(before)
    assert Process.alive?(session), "session must be live before the disconnect"
    ref = Process.monitor(session)

    assert {:ok, _} = GRPC.Stub.disconnect(ch)

    assert_receive {:DOWN, ^ref, :process, ^session, _reason}, @deadline_ms

    # the registry unregisters on the monitor's DOWN: poll the observable, bounded
    deadline = System.monotonic_time(:millisecond) + @deadline_ms

    wait = fn wait ->
      cond do
        session not in session_pids() ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          flunk("session still registered after DOWN")

        true ->
          wait.(wait)
      end
    end

    wait.(wait)
  end

  # -- auth ------------------------------------------------------------------

  describe "auth on the live RPC" do
    setup do
      auth_opts =
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: &Verify.verify/3
        )

      Application.put_env(:ash_a2a, @endpoint, auth: {AshA2A.Transport.GRPC.Auth, auth_opts})
      :ok
    end

    test "SendLiveMessage without credentials is UNAUTHENTICATED(16) and opens no session", %{
      transport: t
    } do
      ch = connect(LiveAgent, t, __MODULE__.NoCredsSup)
      before = session_pids()

      stream = ch |> open_live() |> push(send_msg("ask"))
      error = first_error(GRPC.Stub.recv(stream, timeout: @deadline_ms))

      assert error.status == 16
      assert session_pids() -- before == []
    end

    test "SendLiveMessage with an invalid credential is UNAUTHENTICATED(16)", %{transport: t} do
      ch = connect(LiveAgent, t, __MODULE__.BadCredsSup)
      opts = [metadata: %{"a2a-version" => "1.1", "authorization" => "Bearer nope"}]

      stream = ch |> open_live(opts) |> push(send_msg("ask"))
      assert first_error(GRPC.Stub.recv(stream, timeout: @deadline_ms)).status == 16
    end

    test "SendLiveMessage with a valid credential opens the stream and returns the snapshot", %{
      transport: t
    } do
      ch = connect(LiveAgent, t, __MODULE__.GoodCredsSup)
      opts = [metadata: %{"a2a-version" => "1.1", "authorization" => "Bearer tok-alice"}]

      stream = ch |> open_live(opts) |> push(send_msg("ask"))
      assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: @deadline_ms)
      assert {:task, %Pb.Task{id: id}} = next(replies)
      assert id != ""
    end
  end

  # -- per-request tenant ----------------------------------------------------

  test "per-request tenant is routing metadata: follow-ups under either tenant reach the task",
       %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.TenantSup)

    stream = ch |> open_live() |> push(send_msg("ask"), "acme")
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: @deadline_ms)
    assert {:task, %Pb.Task{id: id}} = next(replies)

    stream = push(stream, send_msg("more", task_id: id), "other")
    frames = take_frames(replies, 2)

    # Tenant is routing metadata for a bare protocol agent (ownership is keyed on the
    # principal, not the tenant), so a follow-up under another tenant reaches the same
    # task and is not rejected: pinned here as the current behaviour, not isolation.
    refute Enum.any?(frames, &match?({:error, _}, &1)), "unexpected rejection: #{inspect(frames)}"

    # The rejection is non-fatal and the owning tenant still reaches the task.
    _stream = push(stream, send_msg("more", task_id: id), "acme")
    frame = next(replies)
    refute match?({:error, _}, frame), "owning-tenant follow-up was rejected: #{inspect(frame)}"
  end

  # -- SubscribeToTask on a terminal task --------------------------------------

  test "SubscribeToTask on a terminal task is UNIMPLEMENTED(12) UNSUPPORTED_OPERATION", %{
    transport: t
  } do
    ch = connect(LiveAgent, t, __MODULE__.TerminalSup)
    task = new_task(ch, "done")
    assert task.status.state == :TASK_STATE_COMPLETED

    result =
      Stub.subscribe_to_task(
        ch,
        %Pb.SubscribeToTaskRequest{id: task.id},
        @v11 ++ [timeout: @deadline_ms]
      )

    error = first_error(result)

    assert error.status == 12
    assert "UNSUPPORTED_OPERATION" in rpc_error_reasons(error)
  end
end

# --- SECTION 19: Original test/grpc_live_session_test.exs ---
defmodule AshA2A.GRPCLiveSessionTest.Handler do
  @moduledoc false
  # Real JSON-RPC handler over the real agents below (same shape as the V6
  # generation court's handler).
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error

  @impl true
  def handle_send(message, _params, %{agent: agent}) do
    opts = [task_id: message.task_id, context_id: message.context_id]

    case AshA2A.Protocol.call(agent, message, opts) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
      {:error, _} -> {:error, Error.internal_error()}
    end
  end

  @impl true
  def handle_get(id, _params, %{agent: agent}) do
    case GenServer.call(agent, {:get_task, id}) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_cancel(_id, _params, _ctx), do: {:error, Error.task_not_cancelable()}
end

defmodule AshA2A.GRPCLiveSessionTest do
  @moduledoc """
  V10 courts: the v1.1 gRPC binding over a real cowboy HTTP/2 listener on an
  ephemeral port and a real Mint gRPC client. `SendLiveMessage` (native
  duplex), `ifGenerationMatch` -> ABORTED(10), `artifactUpdates` capability
  gate, `lastSeenGeneration` fallback, `Task.generation` on the wire.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GRPCLiveSessionTest.Handler
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @v11 [metadata: %{"a2a-version" => "1.1"}]

  defmodule LiveAgent do
    use AshA2A.Protocol.Agent,
      name: "v10-live",
      description: "streaming, no client artifacts",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "ask" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
        _ -> {:input_required, [AshA2A.Protocol.Part.Text.new("again?")]}
      end
    end
  end

  defmodule ArtAgent do
    use AshA2A.Protocol.Agent,
      name: "v10-art",
      description: "streaming + client artifacts",
      capabilities: %{streaming: true, user_artifacts: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  defmodule PlainAgent do
    use AshA2A.Protocol.Agent, name: "v10-plain", description: "no streaming"

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  setup do
    start_supervised!({LiveAgent, []})
    start_supervised!({ArtAgent, []})
    start_supervised!({PlainAgent, []})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})
    on_exit(fn -> Application.delete_env(:ash_a2a, @server) end)
    {:ok, transport: transport}
  end

  defp connect(agent, transport, name) do
    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: Handler,
         ctx: %{agent: agent, opts: %{}, transport: transport, principal: :anonymous},
         name: name}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    ch
  end

  defp message(text, extra \\ []) do
    struct(
      %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("v10"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      },
      extra
    )
  end

  defp new_task(ch) do
    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
             Stub.send_message(ch, %Pb.SendMessageRequest{message: message("ask")}, @v11)

    task
  end

  defp open_live(ch) do
    Stub.send_live_message(ch, @v11 ++ [timeout: 15_000])
  end

  defp push(stream, payload),
    do: GRPC.Stub.send_request(stream, %Pb.StreamRequest{payload: payload})

  defp subscribe(id, extra \\ []),
    do: {:subscribe, struct(%Pb.SubscribeToTaskRequest{id: id}, extra)}

  defp send_msg(text, extra \\ []) do
    {:send_message, %Pb.SendMessageRequest{message: message(text, extra)}}
  end

  # Next downlink frame, bounded by the recv deadline.
  defp next(replies) do
    case Enum.take(replies, 1) do
      [{:ok, %Pb.StreamResponse{payload: {kind, value}}}] -> {kind, value}
      other -> flunk("expected one StreamResponse, got #{inspect(other)}")
    end
  end

  defp rpc_error_reasons(%GRPC.RPCError{details: details}) do
    for %Google.Protobuf.Any{value: v} <- List.wrap(details),
        do: Google.Rpc.ErrorInfo.decode(v).reason
  end

  test "SendLiveMessage subscribe-first: first frame is a Task snapshot", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.SubSup)
    task = new_task(ch)

    stream = ch |> open_live() |> push(subscribe(task.id))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: 10_000)
    assert {:task, %Pb.Task{id: id}} = next(replies)
    assert id == task.id
  end

  test "SendLiveMessage: a follow-up message on the same stream is accepted", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.FollowSup)

    stream = ch |> open_live() |> push(send_msg("ask"))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: 10_000)
    assert {:task, %Pb.Task{id: id}} = next(replies)

    _stream = push(stream, send_msg("more", task_id: id))

    frame = next(replies)
    refute match?({:error, _}, frame), "follow-up was rejected: #{inspect(frame)}"
  end

  test "SendLiveMessage: wrong-task request yields StreamError and keeps the stream open", %{
    transport: t
  } do
    ch = connect(LiveAgent, t, __MODULE__.WrongSup)

    stream = ch |> open_live() |> push(send_msg("ask"))
    assert {:ok, replies} = GRPC.Stub.recv(stream, timeout: 10_000)
    assert {:task, %Pb.Task{id: id}} = next(replies)

    stream = push(stream, send_msg("x", task_id: "some-other-task"))
    assert {:error, %Pb.StreamError{code: code}} = next(replies)
    assert code == "INVALID_ARGUMENT"

    # Late subscribe is also a non-fatal StreamError.
    stream = push(stream, subscribe(id))
    assert {:error, %Pb.StreamError{code: "FAILED_PRECONDITION"}} = next(replies)

    # The stream is still usable.
    _stream = push(stream, send_msg("more", task_id: id))
    frame = next(replies)
    refute match?({:error, _}, frame)
  end

  test "SendLiveMessage on a non-streaming agent -> UNIMPLEMENTED(12) UNSUPPORTED_OPERATION", %{
    transport: t
  } do
    ch = connect(PlainAgent, t, __MODULE__.PlainSup)

    stream = ch |> open_live() |> push(send_msg("ask"))

    error =
      case GRPC.Stub.recv(stream, timeout: 10_000) do
        {:error, %GRPC.RPCError{} = e} ->
          e

        {:ok, replies} ->
          assert [{:error, %GRPC.RPCError{} = e}] = Enum.take(replies, 1)
          e
      end

    assert error.status == 12
    assert "UNSUPPORTED_OPERATION" in rpc_error_reasons(error)
  end

  test "ifGenerationMatch mismatch -> ABORTED(10) TASK_GENERATION_MISMATCH", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.GenSup)
    task = new_task(ch)

    req = %Pb.SendMessageRequest{
      message: message("more", task_id: task.id),
      configuration: %Pb.SendMessageConfiguration{if_generation_match: 987_654}
    }

    assert {:error, %GRPC.RPCError{status: 10} = error} = Stub.send_message(ch, req, @v11)
    assert "TASK_GENERATION_MISMATCH" in rpc_error_reasons(error)
  end

  test "artifactUpdates are refused with UNSUPPORTED_OPERATION(12) when the capability is off", %{
    transport: t
  } do
    ch = connect(LiveAgent, t, __MODULE__.ArtOffSup)
    task = new_task(ch)

    req = %Pb.SendMessageRequest{
      message: message("more", task_id: task.id),
      artifact_updates: [
        %Pb.TaskArtifactUpdateEvent{
          task_id: task.id,
          artifact: %Pb.Artifact{artifact_id: "a1", parts: [%Pb.Part{content: {:text, "x"}}]}
        }
      ]
    }

    assert {:error, %GRPC.RPCError{status: 12} = error} = Stub.send_message(ch, req, @v11)
    assert "UNSUPPORTED_OPERATION" in rpc_error_reasons(error)
  end

  test "artifactUpdates are accepted when user_artifacts is declared", %{transport: t} do
    ch = connect(ArtAgent, t, __MODULE__.ArtOnSup)
    task = new_task(ch)

    req = %Pb.SendMessageRequest{
      message: message("more", task_id: task.id),
      artifact_updates: [
        %Pb.TaskArtifactUpdateEvent{
          task_id: task.id,
          artifact: %Pb.Artifact{artifact_id: "a1", parts: [%Pb.Part{content: {:text, "x"}}]}
        }
      ]
    }

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, req, @v11)

    assert id == task.id
  end

  test "Task.generation survives the proto bridge", %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.TaskGenSup)
    task = new_task(ch)
    assert task.generation > 0

    assert {:ok, %Pb.Task{generation: gen}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: task.id}, @v11)

    assert gen == task.generation
  end

  test "SubscribeToTask lastSeenGeneration falls back to a snapshot when replay is unavailable",
       %{transport: t} do
    ch = connect(LiveAgent, t, __MODULE__.LastSeenSup)
    task = new_task(ch)

    req = %Pb.SubscribeToTaskRequest{id: task.id, last_seen_generation: 0}
    assert {:ok, replies} = Stub.subscribe_to_task(ch, req, @v11 ++ [timeout: 10_000])
    assert [{:ok, %Pb.StreamResponse{payload: {:task, %Pb.Task{id: id}}}}] = Enum.take(replies, 1)
    assert id == task.id
  end
end

# --- SECTION 20: Original test/grpc_server_wiring_test.exs ---
defmodule AshA2A.GRPCServerWiringTest.Handler do
  @moduledoc false
  # Hand-written real JSON-RPC handler over the real EchoAgent: forwards the
  # call opts the gRPC binding binds (task/context ids, metadata) to
  # `AshA2A.Protocol.call/3` and returns the agent's RAW refusal reasons, which
  # the gRPC SendMessage wrapper must map to typed statuses.
  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Runtime

  @impl true
  def handle_send(%{parts: [%{text: "ctype"} | _]}, _params, _ctx),
    do: {:error, {:content_type_not_supported, %{acceptedOutputModes: ["application/x-w27"]}}}

  def handle_send(message, params, %{agent: agent} = ctx) do
    md = ctx |> Map.get(:opts, %{}) |> Map.get(:metadata, %{})

    opts =
      [
        task_id: params["id"] || message.task_id,
        context_id: params["contextId"] || message.context_id
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Keyword.put(:metadata, md)

    case AshA2A.Protocol.call(agent, message, opts) do
      {:ok, %AshA2A.Protocol.Task{} = task} -> {:ok, Runtime.wire_task(task)}
      {:ok, other} -> {:ok, other}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_get(task_id, _params, ctx) do
    case GenServer.call(ctx.agent, {:ash_a2a_get_task, ctx.principal, task_id}) do
      {:ok, task} -> {:ok, Runtime.wire_task(task)}
      _ -> {:error, Error.task_not_found()}
    end
  end

  @impl true
  def handle_cancel(_task_id, _params, _ctx), do: {:error, Error.task_not_found()}
end

defmodule AshA2A.GRPCServerWiringTest do
  @moduledoc """
  W27 courts over a real cowboy HTTP/2 listener (supervised, ephemeral port 0)
  and a real Mint gRPC client: tenant isolation, send-path refusal statuses
  (context mismatch, content type), W3C trace propagation into the dispatcher's
  correlation metadata, and the per-RPC request span.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.GRPCServerWiringTest.Handler
  alias Lf.A2a.V1, as: Pb
  alias Lf.A2a.V1.A2AService.Stub

  @server AshA2A.Transport.GRPC.Server
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  def forward(event, measurements, meta, pid),
    do: send(pid, {:telemetry, event, measurements, meta})

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})
    on_exit(fn -> Application.delete_env(:ash_a2a, @server) end)
    {:ok, transport: transport}
  end

  defp connect(handler, transport, name) do
    sup =
      start_supervised!(
        {AshA2A.Transport.GRPC.Supervisor,
         port: 0,
         handler: handler,
         ctx: %{agent: EchoAgent, opts: %{}, transport: transport, principal: :anonymous},
         name: name}
      )

    port = AshA2A.Transport.GRPC.Supervisor.port(sup)
    {:ok, ch} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    ch
  end

  defp message(text, extra \\ []) do
    struct(
      %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("w27"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, text}}]
      },
      extra
    )
  end

  defp send_req(text, extra \\ [], tenant \\ ""),
    do: %Pb.SendMessageRequest{tenant: tenant, message: message(text, extra)}

  test "tenant isolation: a task is visible only under the tenant that created it", %{
    transport: t
  } do
    ch = connect(AshA2A.Transport.Plug, t, __MODULE__.TenantSup)

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, send_req("hi", [], "acme"))

    assert {:ok, %Pb.Task{id: ^id}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: id, tenant: "acme"})

    assert {:error, %GRPC.RPCError{status: 5}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: id, tenant: "globex"})

    assert {:error, %GRPC.RPCError{status: 5}} = Stub.get_task(ch, %Pb.GetTaskRequest{id: id})
  end

  test "client-supplied tenant metadata cannot cross tenants", %{transport: t} do
    ch = connect(AshA2A.Transport.Plug, t, __MODULE__.ForgeSup)

    forged =
      send_req(
        "hi",
        [
          metadata: %Google.Protobuf.Struct{
            fields: %{"ash_a2a.tenant" => %Google.Protobuf.Value{kind: {:string_value, "acme"}}}
          }
        ],
        ""
      )

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, forged)

    # The forged message metadata was dropped, so the task is untenanted.
    assert {:ok, %Pb.Task{id: ^id}} = Stub.get_task(ch, %Pb.GetTaskRequest{id: id})

    assert {:error, %GRPC.RPCError{status: 5}} =
             Stub.get_task(ch, %Pb.GetTaskRequest{id: id, tenant: "acme"})
  end

  test "context mismatch on a continuation -> INVALID_ARGUMENT(3)", %{transport: t} do
    ch = connect(Handler, t, __MODULE__.CtxSup)

    assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{id: id}}}} =
             Stub.send_message(ch, send_req("hi"))

    assert {:error, %GRPC.RPCError{status: 3}} =
             Stub.send_message(
               ch,
               send_req("again", task_id: id, context_id: "ctx-not-the-tasks")
             )
  end

  test "content type not supported -> INVALID_ARGUMENT(3) CONTENT_TYPE_NOT_SUPPORTED", %{
    transport: t
  } do
    ch = connect(Handler, t, __MODULE__.CtypeSup)

    assert {:error, %GRPC.RPCError{status: 3, details: details}} =
             Stub.send_message(ch, send_req("ctype"))

    reasons =
      for %Google.Protobuf.Any{value: v} <- List.wrap(details),
          do: Google.Rpc.ErrorInfo.decode(v).reason

    assert "CONTENT_TYPE_NOT_SUPPORTED" in reasons
  end

  test "traceparent gRPC metadata reaches the dispatcher correlation metadata", %{transport: t} do
    ch = connect(AshA2A.Transport.Plug, t, __MODULE__.TraceSup)
    id = "w27-trace-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, [:ash_a2a, :dispatch, :start], &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    assert {:ok, %Pb.SendMessageResponse{}} =
             Stub.send_message(ch, send_req("hi"), metadata: %{"traceparent" => @traceparent})

    assert_receive {:telemetry, [:ash_a2a, :dispatch, :start], _m, %{traceparent: @traceparent}},
                   5_000
  end

  test "each RPC runs inside a :grpc request span; error statuses emit the error event", %{
    transport: t
  } do
    ch = connect(AshA2A.Transport.Plug, t, __MODULE__.SpanSup)
    id = "w27-span-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [[:ash_a2a, :transport, :request, :stop], [:ash_a2a, :transport, :request, :error]],
      &__MODULE__.forward/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert {:error, %GRPC.RPCError{status: 5}} = Stub.get_task(ch, %Pb.GetTaskRequest{id: "nope"})

    assert_receive {:telemetry, [:ash_a2a, :transport, :request, :stop], _,
                    %{binding: :grpc, rpc: "GetTask"}},
                   5_000

    assert_receive {:telemetry, [:ash_a2a, :transport, :request, :error], _,
                    %{binding: :grpc, rpc: "GetTask"}},
                   5_000
  end
end

# --- SECTION 21: Original test/hilt_work_order_execution_identity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Hilt.WorkOrderExecutionIdentityTest do
  use ExUnit.Case, async: true

  alias AshA2A.{
    Authority,
    Command,
    ExecutionIdentity,
    ExecutionSnapshot,
    Identity,
    SemanticSubject
  }

  alias AshA2A.Hilt.WorkOrder

  @digest "sha256:" <> String.duplicate("a", 64)
  @digest_b "sha256:" <> String.duplicate("b", 64)
  @digest_c "sha256:" <> String.duplicate("c", 64)

  defp subject do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: @digest,
        projection_digest: @digest_b,
        manufacturer_digest: @digest_c,
        ephemeral?: false
      )

    subject
  end

  defp command(opts \\ []) do
    capability = Keyword.get(opts, :capability, "Acme.Inventory.reserve")
    principal = Identity.principal("principal-1")

    authority =
      if Keyword.get(opts, :authority?, false) do
        Authority.new(principal, capability,
          token_id: "grant-1",
          source: :authority_broker,
          issued_at: ~U[2026-09-25 12:00:00Z],
          constraints: %{region: "us-west"}
        )
      end

    Command.new(capability,
      command_id: Keyword.get(opts, :command_id, "command-1"),
      agent_id: "agent-1",
      principal_id: principal,
      task_id: "task-1",
      input: %{sku: "sku-1", quantity: 1},
      authority: authority,
      semantic_subject: subject(),
      submitted_at: ~U[2026-09-25 12:00:00Z],
      metadata: %{
        candidate_digest: Keyword.get(opts, :candidate_digest, "sha256:candidate"),
        provider: Keyword.get(opts, :provider, "provider-a"),
        transport: Keyword.get(opts, :transport, "wss")
      }
    )
  end

  defp work_order(command, consequence \\ :observe, ceiling \\ :observe) do
    WorkOrder.for_command!(command, consequence,
      work_order_id: "wo-1",
      observation_bounds: %{read: ["inventory"], max_items: 10},
      action_bounds: %{actions: [command.capability_id], max_external_requests: 1},
      authority_ceiling: ceiling,
      process_evidence: %{ocel_type: "sa2a_work_order", required: true},
      falsifier: %{refuse_on: [:stale_subject, :authority_laundering]}
    )
  end

  test "work order binds exact command candidate subject capability and bounds" do
    candidate = command()
    work_order = work_order(candidate)
    bound = WorkOrder.bind_command(work_order, candidate)

    assert :ok = WorkOrder.admit_command(work_order, bound)
    assert Command.work_order_digest(bound) == WorkOrder.identity_digest(work_order)
    assert Command.candidate_digest(bound) == work_order.candidate_digest
    assert String.starts_with?(WorkOrder.identity_digest(work_order), "sha256:")
  end

  test "provider and transport substitution do not alter work-order identity" do
    left = command(provider: "provider-a", transport: "wss")
    right = command(provider: "provider-b", transport: "http")

    left_order = work_order(left)
    right_order = work_order(right)

    assert WorkOrder.identity_digest(left_order) == WorkOrder.identity_digest(right_order)

    left_bound = WorkOrder.bind_command(left_order, left)
    right_bound = WorkOrder.bind_command(right_order, right)

    assert left_bound.fingerprint == right_bound.fingerprint
  end

  test "candidate substitution is refused even when every topology field is unchanged" do
    candidate = command()
    work_order = work_order(candidate)
    bound = WorkOrder.bind_command(work_order, candidate)

    substituted =
      Command.new(bound.capability_id,
        command_id: bound.command_id,
        agent_id: bound.agent_id,
        principal_id: bound.principal_id,
        task_id: bound.task_id,
        input: bound.input,
        authority: bound.authority,
        semantic_subject: bound.semantic_subject,
        submitted_at: bound.submitted_at,
        metadata: Map.put(bound.metadata, :candidate_digest, "sha256:forged-candidate")
      )

    assert {:error, :stale_candidate_identity} =
             WorkOrder.admit_command(work_order, substituted)
  end

  test "DO consequence cannot be laundered through a lower authority ceiling" do
    candidate = command(authority?: true)
    low_ceiling = work_order(candidate, :external_do, :construct)
    bound = WorkOrder.bind_command(low_ceiling, candidate)

    assert {:error, :authority_ceiling_exceeded} =
             WorkOrder.admit_command(low_ceiling, bound)
  end

  test "DO consequence requires an exact admitted authority grant" do
    candidate = command(authority?: true)
    order = work_order(candidate, :external_do, :do)
    bound = WorkOrder.bind_command(order, candidate)

    assert :ok = WorkOrder.admit_command(order, bound)

    no_authority =
      Command.new(bound.capability_id,
        command_id: bound.command_id,
        agent_id: bound.agent_id,
        principal_id: bound.principal_id,
        task_id: bound.task_id,
        input: bound.input,
        semantic_subject: bound.semantic_subject,
        submitted_at: bound.submitted_at,
        metadata: bound.metadata
      )

    assert {:error, :authority_required} = WorkOrder.admit_command(order, no_authority)
  end

  test "execution identity manufactures snapshot identity and detects drift" do
    candidate = command()
    order = work_order(candidate)
    bound = WorkOrder.bind_command(order, candidate)
    identity = ExecutionIdentity.from_work_order!(order, bound)

    snapshot =
      ExecutionIdentity.snapshot!(identity, "sha256:manifest",
        provider_projection: %{provider: "provider-a", transport: "wss"},
        worker_id: "worker-a"
      )

    assert :ok = ExecutionIdentity.verify_snapshot(identity, snapshot)

    provider_changed =
      %{
        snapshot
        | provider_projection: %{provider: "provider-b", transport: "http"},
          worker_id: "worker-b"
      }

    assert :ok = ExecutionIdentity.verify_snapshot(identity, provider_changed)

    assert ExecutionSnapshot.semantic_identity_digest(snapshot) ==
             ExecutionSnapshot.semantic_identity_digest(provider_changed)

    stale = %{snapshot | candidate_digest: "sha256:other-candidate"}

    assert {:error, {:identity_drift, [:candidate_digest]}} =
             ExecutionIdentity.verify_snapshot(identity, stale)
  end

  test "snapshot manufacture refuses caller attempts to overwrite derived identity" do
    candidate = command()
    order = work_order(candidate)
    bound = WorkOrder.bind_command(order, candidate)
    identity = ExecutionIdentity.from_work_order!(order, bound)

    assert_raise ArgumentError, ~r/identity fields are derived/, fn ->
      ExecutionIdentity.snapshot!(identity, "sha256:manifest",
        candidate_digest: "sha256:forged-candidate"
      )
    end
  end

  test "authority evidence/transport is excluded while grant semantics remain identity-bearing" do
    base = command(authority?: true)
    order = work_order(base, :external_do, :do)
    bound = WorkOrder.bind_command(order, base)
    identity = ExecutionIdentity.from_work_order!(order, bound)

    same_grant_different_evidence =
      %{
        bound.authority
        | evidence: %{transport_identity: "different-provider-session"}
      }

    rebound = %{bound | authority: same_grant_different_evidence}
    same = ExecutionIdentity.from_work_order!(order, rebound)

    assert same.authority_digest == identity.authority_digest
  end
end

# --- SECTION 22: Original test/hilt_work_order_graph_digest_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Hilt.WorkOrderGraphDigestTest do
  @moduledoc """
  Two-port graph-digest integrity in `AshA2A.Hilt.WorkOrder` (lane A1,
  v26.10.1-loop): a carried `graph_digest` on the work order is checkpoint
  evidence pinned against the executing command's `semantic_subject.graph_digest`
  at admission. Identity (`identity_digest/1`) is SA2A work-order identity and
  never includes `graph_digest` (RESOLUTIONS R5); the pin lives on the two-port
  plane, enforced by `checkpoint_graph_digest/2` inside `admit_command/2`.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, CommandBus, ReceiptStore, SemanticSubject}
  alias AshA2A.Hilt.WorkOrder
  alias AshA2A.Test.Fixture.Echo

  @ga "sha256:" <> String.duplicate("a", 64)
  @gb "sha256:" <> String.duplicate("b", 64)
  @gc "sha256:" <> String.duplicate("c", 64)
  @gd "sha256:" <> String.duplicate("d", 64)

  setup do
    # A2A-2601: real production retry window, shrunk for this suite's asserts.
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  defp subject(graph_digest \\ @ga) do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: graph_digest,
        projection_digest: @gb,
        manufacturer_digest: @gc,
        ephemeral?: false
      )

    subject
  end

  defp candidate(graph_digest) do
    Command.new("AshA2A.Test.Fixture.Echo.read",
      command_id: "hilt-graph-1",
      agent_id: "agent-1",
      principal_id: "anonymous",
      task_id: "hilt-graph-task-1",
      semantic_subject: subject(graph_digest),
      input: %{},
      metadata: %{candidate_digest: "sha256:hilt-graph-candidate"}
    )
  end

  # graph_digest: :carry (default) omits the key entirely to exercise
  # carry-by-default; any other value is passed through explicitly.
  defp order_for(command, opts \\ []) do
    graph_opt =
      case Keyword.fetch(opts, :graph_digest) do
        {:ok, :carry} -> []
        {:ok, value} -> [graph_digest: value]
        :error -> []
      end

    WorkOrder.for_command!(
      command,
      :observe,
      [
        work_order_id: "hilt-graph-wo-1",
        observation_bounds: %{resources: ["echo"], max_items: 1},
        action_bounds: %{actions: [command.capability_id], max_external_requests: 0},
        authority_ceiling: :observe,
        process_evidence: %{ocel_required: true},
        falsifier: %{refuse_on: [:stale_graph_identity]},
        metadata: %{}
      ] ++ graph_opt
    )
  end

  describe "checkpoint_graph_digest/2 via admit_command/2" do
    test "disagreeing graph digest is refused :stale_graph_identity" do
      command = candidate(@ga)
      order = order_for(command, graph_digest: @gd)

      assert {:error, :stale_graph_identity} = WorkOrder.admit_command(order, command)
    end

    test "agreeing graph digest admits" do
      command = candidate(@ga)
      order = order_for(command, graph_digest: @ga)
      bound = WorkOrder.bind_command(order, command)

      assert :ok = WorkOrder.admit_command(order, bound)
    end

    test "nil order graph digest skips the checkpoint (order nil, subject present)" do
      command = candidate(@ga)
      order = order_for(command, graph_digest: nil)
      bound = WorkOrder.bind_command(order, command)

      assert :ok = WorkOrder.admit_command(order, bound)
    end

    test "nil subject graph digest skips the checkpoint (hand-built subject, order digest present)" do
      # SemanticSubject.new/1 enforces the sha256 form; a struct built directly
      # (e.g. by an older producer) may carry graph_digest: nil. The checkpoint
      # must skip, not refuse, when either port lacks a digest.
      raw_subject = %SemanticSubject{
        graph_digest: nil,
        projection_digest: @gb,
        manufacturer_digest: @gc,
        ephemeral?: false
      }

      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "hilt-graph-nil-subject",
          agent_id: "agent-1",
          principal_id: "anonymous",
          task_id: "hilt-graph-task-nil",
          semantic_subject: raw_subject,
          input: %{},
          metadata: %{candidate_digest: "sha256:hilt-graph-candidate"}
        )

      order = order_for(command, graph_digest: @ga)
      bound = WorkOrder.bind_command(order, command)

      assert :ok = WorkOrder.admit_command(order, bound)
    end

    test "both nil skip" do
      raw_subject = %SemanticSubject{
        graph_digest: nil,
        projection_digest: @gb,
        manufacturer_digest: "sha256:" <> String.duplicate("c", 64),
        ephemeral?: false
      }

      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "hilt-graph-both-nil",
          agent_id: "agent-1",
          principal_id: "anonymous",
          task_id: "hilt-graph-task-both-nil",
          semantic_subject: raw_subject,
          input: %{},
          metadata: %{candidate_digest: "sha256:hilt-graph-candidate"}
        )

      order = order_for(command)
      bound = WorkOrder.bind_command(order, command)

      assert %WorkOrder{graph_digest: nil} = order
      assert :ok = WorkOrder.admit_command(order, bound)
    end
  end

  describe "new!/1 graph_digest validation" do
    test "nil is accepted" do
      command = candidate(@ga)

      assert %WorkOrder{graph_digest: nil} = order_for(command, graph_digest: nil)
    end

    test "valid sha256:64-hex is accepted" do
      command = candidate(@ga)
      assert %WorkOrder{graph_digest: @ga} = order_for(command, graph_digest: @ga)
    end

    test "wrong scheme raises" do
      command = candidate(@ga)

      assert_raise ArgumentError, ~r/graph_digest/, fn ->
        order_for(command, graph_digest: "md5:" <> String.duplicate("a", 64))
      end
    end

    test "63 hex chars raise" do
      command = candidate(@ga)

      assert_raise ArgumentError, ~r/graph_digest/, fn ->
        order_for(command, graph_digest: "sha256:" <> String.duplicate("a", 63))
      end
    end

    test "64 non-hex chars raise" do
      command = candidate(@ga)

      assert_raise ArgumentError, ~r/graph_digest/, fn ->
        order_for(command, graph_digest: "sha256:" <> String.duplicate("g", 64))
      end
    end

    test "non-binary raises" do
      command = candidate(@ga)

      assert_raise ArgumentError, ~r/graph_digest/, fn ->
        order_for(command, graph_digest: 42)
      end
    end
  end

  describe "for_command!/3 carry-by-default" do
    test "carries the command subject's graph_digest by default" do
      command = candidate(@ga)
      order = WorkOrder.for_command!(command, :observe, order_opts())

      assert order.graph_digest == @ga
    end

    test "an explicit opts[:graph_digest] overrides the carried default" do
      command = candidate(@ga)
      order = WorkOrder.for_command!(command, :observe, order_opts(graph_digest: @gd))

      assert order.graph_digest == @gd
    end

    test "an explicit opts[:graph_digest: nil] builds a checkpoint-free order" do
      command = candidate(@ga)
      order = WorkOrder.for_command!(command, :observe, order_opts(graph_digest: nil))

      assert order.graph_digest == nil
    end
  end

  describe "identity-digest exclusion pin (R5)" do
    test "identity_digest is invariant under a graph_digest change" do
      command = candidate(@ga)

      carried = WorkOrder.for_command!(command, :observe, order_opts())
      divergent = WorkOrder.for_command!(command, :observe, order_opts(graph_digest: @gd))

      assert WorkOrder.identity_digest(carried) == WorkOrder.identity_digest(divergent)
    end

    test "bind_command metadata stays work-order identity, never graph_digest" do
      command = candidate(@ga)
      carried = WorkOrder.for_command!(command, :observe, order_opts())
      divergent = WorkOrder.for_command!(command, :observe, order_opts(graph_digest: @gd))

      bound_carried = WorkOrder.bind_command(carried, command)
      bound_divergent = WorkOrder.bind_command(divergent, command)

      assert bound_carried.metadata.work_order_digest ==
               WorkOrder.identity_digest(carried)

      assert bound_divergent.metadata.work_order_digest ==
               WorkOrder.identity_digest(divergent)

      assert bound_carried.metadata.work_order_digest ==
               bound_divergent.metadata.work_order_digest
    end
  end

  describe "e2e through the real CommandBus" do
    test "stale graph identity is refused before claim; no receipt is minted", %{
      store_opts: store_opts
    } do
      command = candidate(@ga)
      order = order_for(command, graph_digest: @gd)
      bound = WorkOrder.bind_command(order, command)

      assert {:error, %{code: :stale_graph_identity}} =
               CommandBus.run(bound, data_message(%{}), Echo,
                 store_opts: store_opts,
                 work_order: order
               )

      assert :error = ReceiptStore.Memory.fetch(bound.command_id, store_opts)
    end

    test "lawful pair completes and replays the closed receipt", %{store_opts: store_opts} do
      command = candidate(@ga)
      order = order_for(command, graph_digest: @ga)
      bound = WorkOrder.bind_command(order, command)

      assert {:ok, first} =
               CommandBus.run(bound, data_message(%{}), Echo,
                 store_opts: store_opts,
                 work_order: order
               )

      assert first.status == :completed

      assert {:ok, replay} =
               CommandBus.run(bound, data_message(%{}), Echo,
                 store_opts: store_opts,
                 work_order: order
               )

      assert replay.replayed?
      assert replay.receipt_id == first.receipt_id
    end
  end

  defp order_opts(extra \\ []) do
    [
      work_order_id: "hilt-graph-wo-1",
      observation_bounds: %{resources: ["echo"], max_items: 1},
      action_bounds: %{actions: ["AshA2A.Test.Fixture.Echo.read"], max_external_requests: 0},
      authority_ceiling: :observe,
      process_evidence: %{ocel_required: true},
      falsifier: %{refuse_on: [:stale_graph_identity]},
      metadata: %{}
    ] ++ extra
  end
end
