defmodule AshA2A.V1TelemetryConformanceTest do
  @moduledoc """
  Conformance court pinning the v1.0-operation telemetry surface of
  `ash_a2a` (lane V26, orthogonal end-to-end conformance).

  Every drive in this file goes through REAL collaborators: real supervised
  `AshA2A.Agent` / `AshA2A.Protocol.Agent` GenServers, the real
  `AshA2A.Transport.Runtime` off-mailbox worker, the real
  `AshA2A.Dispatcher` dispatch span, the real `AshA2A.Protocol.Plug.Auth` +
  `AshA2A.Protocol.Plug` pipeline, and a real `:telemetry` attach handler.
  No Mock/mox/patch/monkeypatch anywhere: a `:telemetry` attach handler is a
  real collaborator, not a test double.

  Pinned reality (the event-name inventory this court establishes):

  ## The ported-SDK `[:a2a, ...]` family (from `AshA2A.Protocol.Telemetry`)

  | Event | Notes |
  | --- | --- |
  | `[:a2a, :agent, :call, :start / :stop]` | span around `AshA2A.Protocol.call/3` / `stream/3`; stop carries `duration` |
  | `[:a2a, :agent, :message, :start / :stop / :exception]` | span around handler execution (`AshA2A.Transport.Runtime.run_handler/3` and the ported `AshA2A.Protocol.Agent.Runtime.run_task/4`) |
  | `[:a2a, :agent, :cancel, :start / :stop]` | span around `handle_cancel/1` on a cancelable (non-terminal, non-in-flight) task |
  | `[:a2a, :task, :transition]` | every task state change |

  ## The repo `[:ash_a2a, ...]` family on the v1.0 operation path

  | Event | Notes |
  | --- | --- |
  | `[:ash_a2a, :agent, :dispatch]` | routing decision (skill_name/consequence/route) |
  | `[:ash_a2a, :dispatch, :start / :stop / :exception]` | dispatch span (`AshA2A.Dispatcher`) |
  | `[:ash_a2a, :dispatch, :brce_gate]` | sole-DO fence verdict (observe => `:not_required`) |
  | `[:ash_a2a, :dispatch, :actuate]` | actuation report (`anchored: false` on the observe path) |
  | `[:ash_a2a, :agent, :cancel]` | cancel observation with resolved actor/tenant |
  | `[:ash_a2a, :receipt, :outboxed / :committed]` | command-bus path only (NOT pinned on the observe drives below) |

  The two families COEXIST on one `message/send`: the `[:a2a, ...]` prefix
  comes from the ported SDK (`AshA2A.Protocol.Telemetry`), the
  `[:ash_a2a, ...]` prefix from the repo (`docs/reference/telemetry.md`).
  That duplication is a FINDING of this court, not something it fixes:
  consumers must attach to BOTH prefixes to observe one operation.

  Redaction invariants pinned (SEC-02's telemetry face):

    * A repo-agent handler raise never reaches the handler span events (the
      span completes with `reply_type: :error`, stop metadata key set
      exactly `{agent, task_id, context_id, reply_type,
      telemetry_span_context}`), and RETURNED dispatch errors are summarized
      data-free in `[:ash_a2a, :dispatch, :stop]` (`%{error: %{kind: _}}`,
      OBS-01).
    * RAW-DETAIL FINDING (pinned as reality, unmodified): raising paths DO
      emit `:exception` events -- `[:ash_a2a, :dispatch, :exception]` for a
      raising Ash action and `[:a2a, :agent, :message, :exception]` for a
      raw `AshA2A.Protocol.Agent` handler raise -- and `:telemetry.span/3`
      merges the RAW kind/reason/stacktrace into those events, so the
      exception message reaches every attached handler verbatim. The
      caller reply, the persisted task, and the redacted stop-metadata path
      all stay clean; the raw detail lives only in these `:exception`
      events (telemetry handlers are the privileged audience per
      `AshA2A.Telemetry.Redact`'s moduledoc) and the server-side ref-logged
      lines. A host forwarding raw telemetry externally does not get the
      same redaction the OCEL forwarder applies.
    * No event metadata anywhere on the authenticated path carries the
      `"a2a.auth"` key, the `AshA2A.Transport.Runtime.owner_key/0` owner
      key, or the raw credential.

  Spec note: the A2A protocol specification (a2a-protocol.org, checked
  2026-10-04) imposes NO normative telemetry/observability requirements
  (only a non-normative "monitoring by aligning with established enterprise
  practices" principle and a logging SHOULD in the error-handling section),
  so this court pins repo-internal consistency, not spec conformance.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.{AuthProbeAgent, StreamItemAgent}

  @marker "V1_TELEMETRY_SECRET_MARKER"
  @credential "raw-credential-V26-court"

  # ---------------------------------------------------------------------------
  # In-file real fixtures: a raw SDK agent whose handler raises, and a repo
  # agent over a resource whose Ash action raises. Both are real GenServers /
  # real Ash resources, not doubles.
  # ---------------------------------------------------------------------------

  defmodule CrashAgent do
    @moduledoc "Real `AshA2A.Protocol.Agent` whose handler always raises."
    use AshA2A.Protocol.Agent, name: "v1-telemetry-crash-agent", description: "raises"

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _context) do
      raise RuntimeError, "V1_TELEMETRY_SECRET_MARKER handler exploded"
    end
  end

  defmodule CrashProbe do
    @moduledoc "Real fixture resource whose generic action raises."
    use Ash.Resource,
      domain: AshA2A.V1TelemetryConformanceTest.CrashProbeDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])

      action :boom, :map do
        run(fn _input, _context ->
          raise RuntimeError, "V1_TELEMETRY_SECRET_MARKER boom"
        end)
      end
    end

    a2a do
      skill(:boom, :boom, consequence: :observe)
    end
  end

  defmodule CrashProbeDomain do
    @moduledoc "Real fixture domain for `CrashProbe`."
    use Ash.Domain, extensions: [AshA2A]

    resources do
      resource(AshA2A.V1TelemetryConformanceTest.CrashProbe)
    end
  end

  defmodule CrashProbeAgent do
    @moduledoc "Real repo agent over `CrashProbe`."
    use AshA2A.Agent, resource_or_domain: CrashProbe, name: "v1_telemetry_crash_probe_agent"
  end

  # ---------------------------------------------------------------------------
  # Telemetry collector: real :telemetry attach handlers, catch-all on both
  # prefixes.
  # ---------------------------------------------------------------------------

  @handler_a2a "v1-telemetry-court-a2a"

  # The exact event names this court enumerates. `:telemetry` (1.4) dispatches
  # by exact name (ETS lookup, no prefix matching), so the enumeration IS the
  # observation surface: these are the documented names of both families on
  # the v1.0 operation path.
  @events_observed [
    # ported-SDK family (AshA2A.Protocol.Telemetry)
    [:a2a, :agent, :call, :start],
    [:a2a, :agent, :call, :stop],
    [:a2a, :agent, :message, :start],
    [:a2a, :agent, :message, :stop],
    [:a2a, :agent, :message, :exception],
    [:a2a, :agent, :cancel, :start],
    [:a2a, :agent, :cancel, :stop],
    [:a2a, :task, :transition],
    # repo family on the v1.0 operation path (docs/reference/telemetry.md)
    [:ash_a2a, :agent, :dispatch],
    [:ash_a2a, :agent, :cancel],
    [:ash_a2a, :agent, :cancel_hook_error],
    [:ash_a2a, :dispatch, :start],
    [:ash_a2a, :dispatch, :stop],
    [:ash_a2a, :dispatch, :exception],
    [:ash_a2a, :dispatch, :brce_gate],
    [:ash_a2a, :dispatch, :actuate]
  ]

  setup do
    :ok =
      :telemetry.attach_many(@handler_a2a, @events_observed, &__MODULE__.handle_event/4, %{
        parent: self()
      })

    on_exit(fn ->
      :telemetry.detach(@handler_a2a)
    end)

    drain()
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, %{parent: parent}) do
    send(parent, {:v1_telemetry_court, {event, measurements, metadata}})
  end

  # All drives are synchronous: every span/event the drive emits is sent to
  # this mailbox BEFORE the drive call returns (the worker emits the span
  # stop before replying; the agent emits cancel events before its reply).
  defp drain(timeout \\ 100) do
    do_drain([], timeout)
  end

  defp do_drain(acc, timeout) do
    receive do
      {:v1_telemetry_court, evt} -> do_drain([evt | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp names(events), do: events |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  defp spans_of(events, base) do
    Enum.filter(events, fn {event, _, _} ->
      event == base ++ [:start] or event == base ++ [:stop] or event == base ++ [:exception]
    end)
  end

  defp assert_span_pair(events, base) do
    assert [{_, start_m, start_meta}] = for({e, m, meta} <- spans_of(events, base), e == base ++ [:start], do: {e, m, meta})

    assert [{_, stop_m, stop_meta}] =
             for({e, m, meta} <- spans_of(events, base), e == base ++ [:stop], do: {e, m, meta})

    assert is_integer(start_m.system_time)
    assert is_integer(stop_m.duration) and stop_m.duration > 0
    {:ok, start_meta, stop_meta}
  end

  defp transitions(events), do: for({[:a2a, :task, :transition], _, meta} <- events, do: meta)

  defp leak_scan(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)
    String.contains?(text, @marker) or String.contains?(text, @credential)
  end

  # Recursively check no map/list/tuple anywhere in a term carries one of the
  # credential-shaped keys.
  @owner_key AshA2A.Transport.Runtime.owner_key()

  defp has_credential_key?("a2a.auth"), do: true
  defp has_credential_key?(@owner_key), do: true
  defp has_credential_key?(_key), do: false

  defp carries_credential_keys?(term) when is_map(term) do
    Enum.any?(term, fn {k, v} -> has_credential_key?(k) or carries_credential_keys?(v) end)
  end

  defp carries_credential_keys?(term) when is_list(term) do
    Enum.any?(term, &carries_credential_keys?/1)
  end

  defp carries_credential_keys?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.any?(&carries_credential_keys?/1)
  end

  defp carries_credential_keys?(_term), do: false

  # Background families excluded from the operation-path inventory: the
  # receipt-outbox reconciler is started by `AshA2A.Application` in test and
  # ticks independently of any drive.
  @background_families [[:ash_a2a, :receipt_outbox], [:ash_a2a, :ocel]]

  defp operation_path_noise?({[[:ash_a2a, :receipt_outbox] | _], _, _}), do: true
  defp operation_path_noise?({[[:ash_a2a, :ocel] | _], _, _}), do: true
  defp operation_path_noise?(_), do: false

  @doc false
  def background_families, do: @background_families

  # -- courts ------------------------------------------------------------------

  describe "message/send telemetry (court a)" do
    test "message/send emits its real span pair with duration and agent+skill metadata" do
      {:ok, _} = start_supervised(AuthProbeAgent)

      message = data_message(%{}, %{metadata: %{"skill" => "whoami"}})

      assert {:ok, %AshA2A.Protocol.Task{} = task} =
               AshA2A.Protocol.call(AuthProbeAgent, message)

      events = drain()

      # (a) the call span: start+stop, real measured duration, agent identity.
      assert {:ok, start_meta, stop_meta} =
               assert_span_pair(events, [:a2a, :agent, :call])

      assert start_meta.agent == AuthProbeAgent
      assert start_meta.streaming == false
      assert stop_meta.task_id == task.id
      assert stop_meta.status == :completed
      assert stop_meta.context_id == task.context_id

      # (a) the handler span: start+stop, real measured duration, agent +
      # task identity, reply type.
      assert {:ok, msg_start_meta, msg_stop_meta} =
               assert_span_pair(events, [:a2a, :agent, :message])

      assert msg_start_meta.agent == AuthProbeAgent
      assert msg_start_meta.task_id == task.id
      assert msg_start_meta.context_id == task.context_id
      assert msg_stop_meta.reply_type == :reply

      # (a) skill identity: the routing event and the dispatch span both name
      # the skill.
      assert [{_, _, route_meta}] =
               for({[:ash_a2a, :agent, :dispatch], _, meta} <- events, do: {[:ash_a2a, :agent, :dispatch], [], meta})

      assert route_meta.resource_or_domain == AshA2A.Test.Fixture.AuthProbe
      assert route_meta.skill_name in [:whoami, "whoami"]
      assert route_meta.consequence == :observe
      assert route_meta.route == :dispatcher

      assert [{_, _, d_start}, {_, _, d_stop}] =
               Enum.sort_by(
                 for({[:ash_a2a, :dispatch, :start] = e, m, meta} <- events, do: {e, m, meta}) ++
                   for({[:ash_a2a, :dispatch, :stop] = e, m, meta} <- events, do: {e, m, meta}),
                 &elem(&1, 0)
               )

      assert d_start.resource_or_domain == AshA2A.Test.Fixture.AuthProbe
      assert d_start.skill_name in [:whoami, "whoami"]
      assert d_stop.reply_type == :reply

      # The sole-DO fence reports on the observe path too: :not_required.
      assert [{_, _, gate}] =
               for({[:ash_a2a, :dispatch, :brce_gate], _, meta} <- events, do: {[:ash_a2a, :dispatch, :brce_gate], [], meta})

      assert gate.outcome == :not_required
      assert gate.skill_name in [:whoami, "whoami"]

      assert [{_, _, actuate}] =
               for({[:ash_a2a, :dispatch, :actuate], _, meta} <- events, do: {[:ash_a2a, :dispatch, :actuate], [], meta})

      assert actuate.anchored == false

      # Task lifecycle transitions are real events: submitted -> working ->
      # completed for this very task.
      trans = Enum.filter(transitions(events), &(&1.task_id == task.id))
      assert [%{from: :submitted, to: :working}, %{from: :working, to: :completed}] = trans
    end
  end

  describe "handler exception redaction (court b, SEC-02 telemetry face)" do
    test "repo-agent action raise: the handler span completes :stop with reply_type :error and no detail; the dispatcher span emits its raw :exception event (FINDING)" do
      {:ok, _} = start_supervised(CrashProbeAgent)

      message = data_message(%{}, %{metadata: %{"skill" => "boom"}})

      assert {:ok, %AshA2A.Protocol.Task{status: %{state: :failed}} = task} =
               AshA2A.Protocol.call(CrashProbeAgent, message)

      events = drain()

      # SEC-02 core: the handler span COMPLETES with :stop (never
      # :exception) -- the transport runtime converts the raise into a typed
      # internal error before the span returns.
      assert {:ok, _start_meta, stop_meta} =
               assert_span_pair(events, [:a2a, :agent, :message])

      assert stop_meta.reply_type == :error

      assert MapSet.new(Map.keys(stop_meta)) ==
               MapSet.new([
                 :agent,
                 :task_id,
                 :context_id,
                 :reply_type,
                 :telemetry_span_context
               ])

      refute Enum.any?(events, &match?({[:a2a, :agent, :message, :exception], _, _}, &1))

      # FINDING (pinned as reality, unmodified): the dispatcher's own span
      # DOES emit [:ash_a2a, :dispatch, :exception] on a raising action, and
      # `:telemetry.span/3` merges the RAW kind/reason/stacktrace into that
      # event's metadata -- the exception message reaches every attached
      # handler verbatim. Returned (non-raising) errors take the redacted
      # OBS-01 stop-metadata path pinned by the sibling test below.
      assert [{_, _, exc_meta}] =
               for({[:ash_a2a, :dispatch, :exception], _, meta} <- events, do: {[:ash_a2a, :dispatch, :exception], [], meta})

      assert exc_meta.kind == :error
      assert inspect(exc_meta.reason) =~ @marker
      assert is_list(exc_meta.stacktrace) and exc_meta.stacktrace != []

      # The ported-SDK family events and the caller-visible failed task stay
      # clean: the marker appears in NO [:a2a, ...] event and not in the task.
      refute Enum.any?(events, fn {event, measurements, metadata} ->
               match?([:a2a | _], event) and (leak_scan(measurements) or leak_scan(metadata))
             end)

      refute leak_scan(task)
    end

    test "returned (non-raising) dispatch error: [:ash_a2a, :dispatch, :stop] carries only the data-free error summary" do
      {:ok, _} = start_supervised(CrashProbeAgent)

      message = data_message(%{}, %{metadata: %{"skill" => "no_such_skill_here"}})

      assert {:ok, %AshA2A.Protocol.Task{status: %{state: :failed}} = task} =
               AshA2A.Protocol.call(CrashProbeAgent, message)

      events = drain()

      assert [{_, _, d_stop}] =
               for({[:ash_a2a, :dispatch, :stop], _, meta} <- events, do: {[:ash_a2a, :dispatch, :stop], [], meta})

      # OBS-01: a RETURNED dispatch error is summarized data-free in the stop
      # metadata -- a kind atom, never the raw reason.
      assert %{error: %{kind: kind}} = d_stop
      assert is_atom(kind)

      refute Enum.any?(events, fn {_event, measurements, metadata} ->
               leak_scan(measurements) or leak_scan(metadata)
             end)

      refute leak_scan(task)
    end

    test "raw SDK agent handler raise: the real [:a2a, :agent, :message, :exception] event fires (carrying raw detail -- FINDING); caller and task stay redacted; agent survives" do
      unique = System.unique_integer([:positive])
      {:ok, pid} = start_supervised({CrashAgent, name: :"v1_telemetry_crash_#{unique}"})

      message = AshA2A.Protocol.Message.new_user("go")

      # The monitored worker crash is converted to a typed redacted internal
      # error for the caller (SEC-02); the agent keeps serving.
      assert {:error, %{code: :internal_error, ref: ref}} = CrashAgent.call(pid, message)
      assert is_binary(ref)

      events = drain()

      # The ported span wraps the handler unrescued, so the raise really does
      # emit the exception event -- pinned as reality.
      assert [{_, exc_m, exc_meta}] =
               for({[:a2a, :agent, :message, :exception] = e, m, meta} <- events, do: {e, m, meta})

      assert is_integer(exc_m.duration) and exc_m.duration > 0

      # FINDING (pinned as reality, unmodified): `:telemetry.span/3` merges
      # the RAW kind/reason/stacktrace into the exception event, so the
      # handler's exception message and stack reach every telemetry handler
      # on this ported path. The repo-facing guarantee (typed error +
      # redacted caller/task + NO exception event on the repo handler span)
      # is pinned by the sibling test above.
      assert exc_meta.kind == :error
      assert inspect(exc_meta.reason) =~ @marker
      assert is_list(exc_meta.stacktrace) and exc_meta.stacktrace != []
      assert exc_meta.agent == CrashAgent
      assert is_binary(exc_meta.task_id)

      # The span ended in :exception, not :stop.
      refute Enum.any?(events, &match?({[:a2a, :agent, :message, :stop], _, _}, &1))

      # The crashed turn's task was never persisted (the ported runtime
      # builds the task inside the crashed worker): the caller gets the typed
      # error and `tasks/get` answers :not_found -- nothing marker-bearing
      # exists behind the agent.
      assert {:error, :not_found} = CrashAgent.get_task(pid, exc_meta.task_id)

      # The agent survived the worker crash.
      assert Process.alive?(pid)
    end
  end

  describe "tasks/cancel telemetry (court c)" do
    test "cancel of a working streaming task emits the cancel span pair and the repo cancel event" do
      {:ok, _} = start_supervised(StreamItemAgent)

      message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})

      assert {:ok, %AshA2A.Protocol.Task{} = task} = StreamItemAgent.call(message)
      assert task.status.state == :working
      _ = drain()

      assert :ok = StreamItemAgent.cancel(task.id)

      events = drain()

      # The ported cancel span: start+stop around the real handle_cancel.
      assert {:ok, start_meta, stop_meta} =
               assert_span_pair(events, [:a2a, :agent, :cancel])

      assert start_meta.agent == StreamItemAgent
      assert start_meta.task_id == task.id
      assert start_meta.context_id == task.context_id
      # Stop metadata is the span meta unchanged for cancel (no stop-only keys).
      assert stop_meta.task_id == task.id

      # The repo-level cancel observation.
      assert [{_, _, cancel_meta}] =
               for({[:ash_a2a, :agent, :cancel], _, meta} <- events, do: {[:ash_a2a, :agent, :cancel], [], meta})

      assert cancel_meta.resource_or_domain == AshA2A.Test.Fixture.StreamItem
      assert cancel_meta.task_id == task.id
      assert cancel_meta.context_id == task.context_id
      assert cancel_meta.actor == nil

      # The canceled transition is a real event for this task.
      assert [%{from: :working, to: :canceled}] =
               Enum.filter(transitions(events), &(&1.task_id == task.id))

      # The message span for the original send is background of this drive
      # window (already drained); the cancel drive emits no message span.
      refute Enum.any?(events, &match?({[:a2a, :agent, :message, :start], _, _}, &1))
    end

    test "refusing a terminal-task cancel emits no cancel telemetry" do
      {:ok, _} = StreamItemAgent |> start_supervised()

      message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})

      assert {:ok, %AshA2A.Protocol.Task{} = task} = StreamItemAgent.call(message)
      assert task.status.state == :working
      drain()

      assert :ok = StreamItemAgent.cancel(task.id)
      drain()

      # Now terminal: idempotent success (v1.0 §3.3.1) — and the idempotent
      # branch returns BEFORE the cancel span, so still no cancel telemetry.
      assert :ok = StreamItemAgent.cancel(task.id)

      events = drain()

      assert [] =
               Enum.filter(events, fn {event, _, _} ->
                 event == [:a2a, :agent, :cancel, :start] or
                   event == [:ash_a2a, :agent, :cancel]
               end)
    end
  end

  describe "authenticated message/send (court e)" do
    test "no event metadata over a full authenticated message/send carries a2a.auth, the owner key, or the raw credential" do
      {:ok, _} = start_supervised(AuthProbeAgent)

      schemes = %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

      auth_opts =
        AshA2A.Protocol.Plug.Auth.init(schemes: schemes, verify: &__MODULE__.verify/3)

      plug_opts =
        AshA2A.Protocol.Plug.init(agent: AuthProbeAgent, base_url: "http://localhost:4000/a2a")

      message =
        %{AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])
          | metadata: %{"skill" => "whoami"}}

      {:ok, message_json} = AshA2A.Protocol.JSON.encode(message)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "req-1",
          "method" => "message/send",
          "params" => %{"message" => message_json}
        })

      conn =
        :post
        |> Plug.Test.conn("/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> @credential)
        |> AshA2A.Protocol.Plug.Auth.call(auth_opts)

      refute conn.halted

      conn = AshA2A.Protocol.Plug.call(conn, plug_opts)
      assert conn.status == 200

      events = drain()

      # The full authenticated path really ran (same surface as court a).
      assert Enum.any?(events, &match?({[:a2a, :agent, :message, :start], _, _}, &1))
      assert Enum.any?(events, &match?({[:a2a, :agent, :message, :stop], _, _}, &1))
      assert Enum.any?(events, &match?({[:ash_a2a, :dispatch, :stop], _, _}, &1))

      # THE court: no event anywhere carries the credential keys or values.
      refute Enum.any?(events, fn {_event, measurements, metadata} ->
               carries_credential_keys?(measurements) or carries_credential_keys?(metadata) or
                 leak_scan(measurements) or leak_scan(metadata)
             end)
    end

    def verify("bearer_auth", @credential, _conn), do: {:ok, %{id: "user-42", tenant: "acme"}}
    def verify(_scheme, _credential, _conn), do: {:error, "invalid token"}
  end

  describe "event-name inventory (court d)" do
    test "the operation path emits exactly the documented event families" do
      {:ok, _} = start_supervised(AuthProbeAgent)
      {:ok, _} = start_supervised(StreamItemAgent)

      # -- drive 1: message/send (observe skill) via Protocol.call
      message = data_message(%{}, %{metadata: %{"skill" => "whoami"}})
      assert {:ok, %AshA2A.Protocol.Task{}} = AshA2A.Protocol.call(AuthProbeAgent, message)
      send_events = drain()

      # -- drive 2: tasks/cancel of a working streaming task
      stream_message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})
      assert {:ok, %AshA2A.Protocol.Task{} = working} = StreamItemAgent.call(stream_message)
      assert working.status.state == :working
      stream_events = drain()
      assert :ok = StreamItemAgent.cancel(working.id)
      cancel_events = drain()

      all = send_events ++ stream_events ++ cancel_events

      operation_names =
        all
        |> Enum.reject(&operation_path_noise?/1)
        |> names()

      # (d) exactly this set: the seven ported-SDK names plus the six repo
      # operation-path names, each observed.
      assert Enum.sort(operation_names) ==
               Enum.sort([
                 [:a2a, :agent, :call, :start],
                 [:a2a, :agent, :call, :stop],
                 [:a2a, :agent, :message, :start],
                 [:a2a, :agent, :message, :stop],
                 [:a2a, :agent, :cancel, :start],
                 [:a2a, :agent, :cancel, :stop],
                 [:a2a, :task, :transition],
                 [:ash_a2a, :agent, :cancel],
                 [:ash_a2a, :agent, :dispatch],
                 [:ash_a2a, :dispatch, :start],
                 [:ash_a2a, :dispatch, :brce_gate],
                 [:ash_a2a, :dispatch, :actuate],
                 [:ash_a2a, :dispatch, :stop]
               ])
    end
  end
end
