# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Telemetry and Semantic Work
# Contains original tests:
#   - test/ash_a2a/telemetry/allocation_counters_test.exs
#   - test/ash_a2a/telemetry/metrics_emission_test.exs
#   - test/ash_a2a/telemetry/metrics_test.exs
#   - test/ash_a2a/telemetry/obs_hardening_test.exs
#   - test/ash_a2a/telemetry/ocel_boot_warning_test.exs
#   - test/ash_a2a/telemetry/ocel_dispatch_parity_test.exs
#   - test/ash_a2a/telemetry/ocel_forwarder_egress_test.exs
#   - test/ash_a2a/telemetry/redact_test.exs
#   - test/ash_a2a/telemetry/router_counters_isolation_test.exs
#   - test/pm4exunit/multi_agent_pm4_test.exs
#   - test/pm4exunit/planned_agents_pm4_test.exs
#   - test/semantic_work/admission_test.exs
#   - test/semantic_work/candidate_test.exs
#   - test/semantic_work/checkpoint_test.exs
#   - test/semantic_work/envelope_test.exs
#   - test/semantic_work/graph_identity_test.exs
#   - test/semantic_work/lease_test.exs
#   - test/semantic_work/projection_test.exs
#   - test/semantic_work/provider_test.exs
#   - test/semantic_work/work_order_test.exs
#   - test/telemetry_bridge/pplan_hazard_bridge_test.exs
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION 1: Original test/ash_a2a/telemetry/allocation_counters_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.AllocationCountersTest do
  @moduledoc """
  The real instrument behind RFC S65's `Allocation_LLM(class, t+1) <=
  Allocation_LLM(class, t)` claim.

  Real `:telemetry`, real `:ets`, real events emitted by the real
  `AshA2A.Semantic.Unknown.route/3` -- assertions are on the real
  accumulated integers.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Allocator, Unknown}
  alias AshA2A.Telemetry.AllocationCounters

  # `owner: self()` makes the measurement genuinely this test's own.
  # `:telemetry` handlers attach to an event NAME globally and run in the
  # emitting process, so without it a concurrent `async: true` test that
  # also routes a real UNKNOWN lands its allocations in this table and the
  # whole-table `counts/1` assertion below becomes order-dependent.
  defp attached do
    tid = AllocationCounters.new()
    handler = AllocationCounters.attach!(tid, make_ref(), owner: self())
    on_exit(fn -> AllocationCounters.detach(handler) end)
    tid
  end

  defp budget, do: Allocator.new!(inference_calls: 1, compute_units: 1)

  test "an unobserved pair is a real zero, not missing data" do
    tid = attached()
    assert AllocationCounters.allocation(tid, "never-seen", :llm) == 0
    assert AllocationCounters.counts(tid) == %{}
  end

  test "real route/3 calls accumulate per class and per resolver" do
    tid = attached()

    resolver = fn %Unknown{} -> {:ok, %{"answer" => 1}} end

    assert {:ok, :resolved, _r, _b} =
             Unknown.route("class-a", %{}, budget: budget(), resolver: {:llm, resolver})

    assert {:ok, :resolved, _r, _b} =
             Unknown.route("class-a", %{}, budget: budget(), resolver: {:llm, resolver})

    assert {:ok, :resolved, _r, _b} =
             Unknown.route("class-b", %{}, budget: budget(), resolver: {:prover, resolver})

    assert AllocationCounters.allocation(tid, "class-a", :llm) == 2
    assert AllocationCounters.allocation(tid, "class-b", :prover) == 1
    assert AllocationCounters.allocation(tid, "class-b", :llm) == 0

    assert AllocationCounters.counts(tid) == %{
             "class-a" => %{llm: 2},
             "class-b" => %{prover: 1}
           }
  end

  test "a resolver that fails still records the spend it actually made" do
    tid = attached()

    assert {:unknown, %Unknown{reason: :resolver_failed}, _reason} =
             Unknown.route("burned-class", %{},
               budget: Allocator.new!(inference_calls: 1),
               resolver: {:llm, fn %Unknown{} -> {:error, :timeout} end}
             )

    # The call was made and the budget was spent; not counting it would
    # under-report real cost.
    assert AllocationCounters.allocation(tid, "burned-class", :llm) == 1
  end

  test "a route refused BEFORE the resolver call records no spend" do
    tid = attached()

    assert {:unknown, %Unknown{reason: :allocation_exhausted}, _reason} =
             Unknown.route("unspent-class", %{},
               resolver: {:llm, fn %Unknown{} -> {:ok, %{}} end}
             )

    assert AllocationCounters.allocation(tid, "unspent-class", :llm) == 0
  end

  test "two independent instruments never share state" do
    one = attached()
    two = attached()

    assert {:ok, :resolved, _r, _b} =
             Unknown.route("shared-class", %{},
               budget: Allocator.new!(inference_calls: 1),
               resolver: {:llm, fn %Unknown{} -> {:ok, %{}} end}
             )

    # Both are attached, so both saw it -- and detaching one later must
    # not disturb the other's accumulated counts.
    assert AllocationCounters.allocation(one, "shared-class", :llm) == 1
    assert AllocationCounters.allocation(two, "shared-class", :llm) == 1

    fresh = AllocationCounters.new()
    assert AllocationCounters.allocation(fresh, "shared-class", :llm) == 0
  end

  test "non_increasing?/2 is a real comparison over two measured integers" do
    assert AllocationCounters.non_increasing?(10, 10)
    assert AllocationCounters.non_increasing?(10, 3)
    refute AllocationCounters.non_increasing?(3, 10)
  end

  test "a malformed event fails closed instead of crashing the emitting process" do
    tid = attached()

    :telemetry.execute(Unknown.allocation_event(), %{count: 1}, %{unexpected: :shape})

    assert AllocationCounters.counts(tid) == %{}
  end
end

# ------------------------------------------------------------------------------
# SECTION 2: Original test/ash_a2a/telemetry/metrics_emission_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.MetricsEmissionTest do
  @moduledoc """
  Every `AshA2A.Telemetry.Metrics.definitions/0` entry names an event,
  measurement and tags that a REAL emitter actually produces -- so a
  definition can never silently record nothing (a metric whose tag is absent
  from the emitted metadata is dropped by reporters).

  Real emitters driven here: `Dispatcher.dispatch/3`, `Health.readiness/0`,
  `Authority.Decision.verdict/1`, `Authority.Grant.authorize/3`,
  `OcelBroadcaster` (dropped / flush_failed / unconvertible), `OcelForwarder`
  (delivered / failed / shed / unconvertible, against a real local listener
  and a real dead port), `ReceiptOutbox.Reconciler` (tick / stuck / corrupt),
  and `:telemetry.span/3` for the dispatch exception (the library's own
  emitter -- `Dispatcher` only raises through it on an uncaught crash).

  Documented exemptions (`@source_witnessed`): events whose emitter needs a
  full CommandBus commit; they are witnessed in the emitting source instead
  (including the `:duration` measurement on `command_bus.actuate.stop`).
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  import ExUnit.CaptureLog

  alias AshA2A.Telemetry.{Metrics, OcelBroadcaster, OcelForwarder}
  alias AshA2A.Test.Fixture.FreedomGym.Facilitator

  # Counters count occurrences; their nominal measurement is never read.
  @nominal_counter_events [
    [:ash_a2a, :authority, :decision_envelope, :verdict],
    [:ash_a2a, :ocel_broadcaster, :dropped],
    [:ash_a2a, :ocel_broadcaster, :flush_failed],
    [:ash_a2a, :ocel_broadcaster, :unconvertible],
    [:ash_a2a, :ocel, :unconvertible],
    [:ash_a2a, :receipt, :committed],
    [:ash_a2a, :receipt, :outboxed]
  ]

  # event => {source file, literals that must appear in it}
  @source_witnessed %{
    [:ash_a2a, :receipt, :committed] =>
      {"lib/ash_a2a/command_bus.ex", ["[:ash_a2a, :receipt, :committed]"]},
    [:ash_a2a, :receipt, :outboxed] =>
      {"lib/ash_a2a/command_bus.ex", ["[:ash_a2a, :receipt, :outboxed]"]},
    [:ash_a2a, :command_bus, :actuate, :stop] =>
      {"lib/ash_a2a/command_bus.ex",
       ["emit_boundary([:actuate, :stop]", "%{duration: duration}", "capability_id:"]}
  }

  defmodule OkIngest do
    @moduledoc false
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      Plug.Conn.send_resp(conn, 201, "{}")
    end

    match(_) do
      Plug.Conn.send_resp(conn, 404, "no")
    end
  end

  setup do
    test_pid = self()
    ref = make_ref()

    events = Enum.map(Metrics.definitions(), & &1.event) |> Enum.uniq()

    for event <- events do
      :telemetry.attach(
        {__MODULE__, ref, event},
        event,
        fn ev, m, md, _ -> send(test_pid, {:telemetry, ev, m, md}) end,
        nil
      )
    end

    outbox_dir =
      Path.join(
        System.tmp_dir!(),
        "ash-a2a-metrics-emission-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)
    :ok = OcelForwarder.attach!()

    on_exit(fn ->
      for event <- events, do: :telemetry.detach({__MODULE__, ref, event})
      OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
      Application.delete_env(:ash_a2a, :ocel_task_supervisor)
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      File.rm_rf!(outbox_dir)
    end)

    {:ok, outbox_dir: outbox_dir}
  end

  defp collect(acc \\ %{}) do
    receive do
      {:telemetry, event, m, md} -> collect(Map.update(acc, event, [{m, md}], &[{m, md} | &1]))
    after
      0 -> acc
    end
  end

  defp await_event(event, timeout \\ 5_000) do
    receive do
      {:telemetry, ^event, m, md} ->
        send(self(), {:telemetry, event, m, md})
        :ok
    after
      timeout -> flunk("no #{inspect(event)} emitted within #{timeout}ms")
    end
  end

  defp dispatch_meta do
    %{resource_or_domain: Facilitator, skill_name: :run_phase, reply_type: :reply}
  end

  defp drive_dispatch_and_health do
    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{
          "phase" => :trust_god,
          "prompt_text" => "Name one thing."
        })
      ])

    assert {:reply, _} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator)
    _ = AshA2A.Health.readiness()

    assert {:refused, _} = AshA2A.Authority.Decision.verdict(%{})

    _ = AshA2A.Authority.Grant.authorize(AshA2A.Identity.principal("metrics-p"), "metrics.cap")

    try do
      :telemetry.span([:ash_a2a, :dispatch], dispatch_meta(), fn -> raise "boom" end)
    rescue
      RuntimeError -> :ok
    end
  end

  # The real per-binding request span (`Protocol.Telemetry.request_span/3`):
  # one ok request (stop) and one failed request (stop + error).
  defp drive_transport_request do
    for binding <- [:jsonrpc, :http_json, :grpc] do
      assert :ok = AshA2A.Protocol.Telemetry.request_span(binding, fn -> {:ok, true} end)
      assert :err = AshA2A.Protocol.Telemetry.request_span(binding, fn -> {:err, false} end)
    end
  end

  defp drive_broadcaster do
    name = :"metrics_emission_bc_#{System.unique_integer([:positive])}"

    start_supervised!(
      {OcelBroadcaster,
       name: name,
       endpoints: [
         [platform: :chronicle, endpoint: "http://127.0.0.1:1", api_key: "k", max_retries: 0]
       ],
       max_buffer: 1,
       flush_interval_ms: false}
    )

    capture_log(fn ->
      :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, dispatch_meta())
      :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, dispatch_meta())
      # malformed receipt metadata -> unconvertible
      :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: :nope})
      assert OcelBroadcaster.unconvertible_count(name) == 1
      assert :ok = OcelBroadcaster.flush(name)
    end)
  end

  defp drive_forwarder do
    capture_log(fn ->
      Application.put_env(:ash_a2a, :ocel_ingest_url, "http://127.0.0.1:1")
      :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, dispatch_meta())
      await_event([:ash_a2a, :ocel, :failed])

      Application.put_env(:ash_a2a, :ocel_task_supervisor, :metrics_emission_no_such_supervisor)
      :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, dispatch_meta())
      Application.delete_env(:ash_a2a, :ocel_task_supervisor)

      :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: :nope})

      %{base_url: url} = AshA2A.Test.EphemeralHttp.start!(OkIngest)
      Application.put_env(:ash_a2a, :ocel_ingest_url, url)
      :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, dispatch_meta())
      await_event([:ash_a2a, :ocel, :delivered])
    end)
  end

  defp drive_reconciler(outbox_dir) do
    File.write!(Path.join(outbox_dir, "runtime:corrupt.receipt"), <<1, 2, 3>>)

    command =
      AshA2A.Command.new("AshA2A.Test.Fixture.metrics_probe",
        command_id: "metrics-stuck",
        agent_id: "agent-metrics",
        principal_id: AshA2A.Identity.principal("metrics-p")
      )

    receipt =
      command
      |> AshA2A.Receipt.pending(AshA2A.Identity.execution("exec-metrics"), :change)
      |> Map.put(:reconciliation, %{state: :pending, attempts: 9})

    :ok = AshA2A.ReceiptOutbox.append(receipt)

    name = :"metrics_emission_rec_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AshA2A.ReceiptOutbox.Reconciler,
       name: name,
       interval_ms: 60_000,
       stuck_attempts_threshold: 5,
       store: AshA2A.ReceiptStore.Memory,
       store_opts: [
         name: :"metrics_emission_unstarted_store_#{System.unique_integer([:positive])}"
       ]}
    )

    assert {:ok, _} = AshA2A.ReceiptOutbox.Reconciler.tick(name)
  end

  test "every Metrics definition's event, measurement and tags are emitted by a real emitter",
       %{outbox_dir: outbox_dir} do
    drive_dispatch_and_health()
    drive_transport_request()
    drive_broadcaster()
    drive_forwarder()
    drive_reconciler(outbox_dir)

    observed = collect()

    for d <- Metrics.definitions(), not Map.has_key?(@source_witnessed, d.event) do
      emissions = Map.get(observed, d.event, [])

      assert emissions != [],
             "#{d.name}: event #{inspect(d.event)} never emitted by a real emitter"

      measurement_ok? =
        (d.type == :counter and d.event in @nominal_counter_events) or
          Enum.any?(emissions, fn {m, _} -> Map.has_key?(m, d.measurement) end)

      assert measurement_ok?, "#{d.name}: measurement #{inspect(d.measurement)} never emitted"

      assert Enum.any?(emissions, fn {_, md} -> Enum.all?(d.tags, &Map.has_key?(md, &1)) end),
             "#{d.name}: tags #{inspect(d.tags)} never all present in emitted metadata"
    end
  end

  test "source-witnessed definitions: the emitting source still carries event, measurement and tag" do
    root = Path.expand("../../..", __DIR__)

    for d <- Metrics.definitions(), {file, literals} <- List.wrap(@source_witnessed[d.event]) do
      source = File.read!(Path.join(root, file))

      for literal <- literals do
        assert source =~ literal, "#{d.name}: #{literal} missing from #{file}"
      end
    end
  end

  test "every definition name is unique and metrics/0 stays in step" do
    names = Enum.map(Metrics.definitions(), & &1.name)
    assert names == Enum.uniq(names)
  end
end

# ------------------------------------------------------------------------------
# SECTION 3: Original test/ash_a2a/telemetry/metrics_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.MetricsTest do
  use ExUnit.Case, async: true

  alias AshA2A.Telemetry.Metrics

  test "every definition names a real :ash_a2a event and a measurement" do
    defs = Metrics.definitions()
    assert length(defs) >= 8

    for d <- defs do
      assert [:ash_a2a | _] = d.event
      assert d.type in [:summary, :distribution, :counter, :last_value]
      full = Enum.map_join(d.event ++ [d.measurement], ".", &Atom.to_string/1)

      # A counter counts occurrences, so it may be named `<event>.count`
      # (dropping a trailing :stop span suffix) instead of by measurement.
      count_name =
        d.event
        |> Enum.reject(&(&1 == :stop))
        |> Enum.map_join(".", &Atom.to_string/1)
        |> Kernel.<>(".count")

      base_name =
        d.event
        |> Enum.reject(&(&1 == :stop))
        |> Enum.map_join(".", &Atom.to_string/1)

      stripped_name = base_name <> "." <> Atom.to_string(d.measurement)

      assert d.name == full or d.name == stripped_name or
               (d.type == :counter and d.name == count_name),
             "#{d.name} matches none of #{full}, #{stripped_name}, #{count_name}"
    end
  end

  test "metrics/0 fails with a clear message when :telemetry_metrics is absent" do
    if Code.ensure_loaded?(Telemetry.Metrics) do
      assert length(Metrics.metrics()) == length(Metrics.definitions())
    else
      assert_raise ArgumentError, ~r/requires the :telemetry_metrics dependency/, fn ->
        Metrics.metrics()
      end
    end
  end
end

# ------------------------------------------------------------------------------
# SECTION 4: Original test/ash_a2a/telemetry/obs_hardening_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.ObsHardeningTest do
  @moduledoc """
  OBS-01/02/03/05/12 qualification for the observability egress, Chicago
  style: real `AshA2A.Dispatcher.dispatch/6`, the real application-attached
  `AshA2A.Telemetry.OcelForwarder` handlers, a real Bandit HTTP ingest, real
  `Req` POSTs and real `:telemetry` handlers. No mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  import ExUnit.CaptureLog
  require Logger
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Telemetry.{OcelForwarder, Redact}

  defmodule Ingest do
    @moduledoc false
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      %{"events" => events} = conn.body_params
      {status, owner} = Agent.get(__MODULE__.Store, & &1)
      send(owner, {:ingested, events})
      Plug.Conn.send_resp(conn, status, "secret-response-body token=abc123")
    end
  end

  setup do
    parent = self()

    start_supervised!(%{
      id: Ingest.Store,
      start: {Agent, :start_link, [fn -> {201, parent} end, [name: Ingest.Store]]}
    })

    port = Enum.random(23_000..23_999)
    start_supervised!({Bandit, plug: Ingest, port: port, ip: {127, 0, 0, 1}})

    previous =
      for key <- [:ocel_ingest_url, :ocel_log_interval_ms, :ocel_task_supervisor, :ocel_log_body],
          do: {key, Application.get_env(:ash_a2a, key)}

    :ok = OcelForwarder.attach!()

    Application.put_env(
      :ash_a2a,
      :ocel_ingest_url,
      "http://obsuser:s3cr3t-token@127.0.0.1:#{port}"
    )

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:ash_a2a, key),
          else: Application.put_env(:ash_a2a, key, value)
      end
    end)

    %{port: port}
  end

  defp set_ingest_status(status), do: Agent.update(Ingest.Store, fn {_s, o} -> {status, o} end)

  defp probe(events) do
    ref = make_ref()
    parent = self()
    id = {__MODULE__, ref}

    :ok =
      :telemetry.attach_many(
        id,
        events,
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata, Logger.metadata()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  defp emit_dispatch_stop(extra \\ %{}) do
    :telemetry.execute(
      [:ash_a2a, :dispatch, :stop],
      %{duration: 1_000},
      Map.merge(%{resource_or_domain: AshA2A.Test.Fixture.Item, skill_name: "obs_probe"}, extra)
    )
  end

  describe "OBS-01: dispatch stop metadata carries a redacted error" do
    test "an unknown-skill refusal reaches telemetry as a data-free summary; the reply is unchanged" do
      ref = probe([[:ash_a2a, :dispatch, :stop]])
      Application.delete_env(:ash_a2a, :ocel_ingest_url)

      reply =
        AshA2A.Dispatcher.dispatch(
          "no_such_skill_secret_input",
          data_message(%{"password" => "hunter2"}),
          AshA2A.Test.Fixture.Item
        )

      assert {:error, {:skill_lookup, raw}} = reply
      assert inspect(raw) =~ "no_such_skill_secret_input"

      assert_receive {^ref, [:ash_a2a, :dispatch, :stop], _m, meta, _md}, 1_000
      assert meta.stage == :skill_lookup
      assert %{kind: kind} = meta.error
      assert is_atom(kind)
      refute inspect(meta.error) =~ "no_such_skill_secret_input"
    end

    test "raw error terms return only under the explicit :telemetry_raw_errors opt-in" do
      Application.put_env(:ash_a2a, :telemetry_raw_errors, true)
      on_exit(fn -> Application.delete_env(:ash_a2a, :telemetry_raw_errors) end)
      assert Redact.telemetry_error({:x, "raw"}) == {:x, "raw"}
      Application.delete_env(:ash_a2a, :telemetry_raw_errors)
      assert Redact.telemetry_error({:x, "raw"}) == %{kind: :x}
    end

    test "the OCEL body error attribute is the kind only, even for a raw error term" do
      emit_dispatch_stop(%{stage: :execution, error: %{code: :boom, detail: "token=abc123"}})
      assert_receive {:ingested, [event]}, 2_000
      assert event["attributes"]["error"] == "boom"
      refute Jason.encode!(event) =~ "abc123"
    end
  end

  describe "OBS-12: correlation" do
    test "command_id/task_id/traceparent reach dispatch start metadata and Logger metadata, then are restored" do
      ref = probe([[:ash_a2a, :dispatch, :start]])
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
      tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
      msg = data_message(%{}, %{metadata: %{"traceparent" => tp}})
      Logger.metadata(ash_a2a_task_id: "outer")

      AshA2A.Dispatcher.dispatch("no_such_skill", msg, AshA2A.Test.Fixture.Item, [], nil,
        command_id: "cmd-1",
        task_id: "task-1"
      )

      assert_receive {^ref, [:ash_a2a, :dispatch, :start], _m, meta, logger_md}, 1_000
      assert meta.command_id == "cmd-1"
      assert meta.task_id == "task-1"
      assert meta.traceparent == tp
      assert logger_md[:ash_a2a_traceparent] == tp
      assert logger_md[:ash_a2a_command_id] == "cmd-1"
      # restored after the dispatch
      assert Logger.metadata()[:ash_a2a_task_id] == "outer"
      assert Logger.metadata()[:ash_a2a_traceparent] == nil
      Logger.metadata(ash_a2a_task_id: nil)
    end

    test "a malformed traceparent from the wire is not admitted" do
      msg = data_message(%{}, %{metadata: %{"traceparent" => "not-a-traceparent\nINJECT"}})
      assert AshA2A.Dispatcher.correlation_meta(msg, []) == %{}
    end

    test "oversized correlation ids (bare or identity-wrapped) are not admitted" do
      msg = data_message(%{}, %{})
      big = String.duplicate("a", 257)

      assert AshA2A.Dispatcher.correlation_meta(msg,
               command_id: %{value: big},
               task_id: big
             ) == %{}

      assert AshA2A.Dispatcher.correlation_meta(msg, command_id: %{value: "c-1"}) ==
               %{command_id: "c-1"}
    end
  end

  describe "OBS-02/03: delivery accounting and egress hygiene" do
    test "a 2xx delivery increments delivered_count and emits :delivered with a credential-free endpoint",
         %{port: port} do
      ref = probe([[:ash_a2a, :ocel, :delivered]])
      before = OcelForwarder.delivered_count()
      emit_dispatch_stop()
      assert_receive {^ref, _, %{duration: d}, %{endpoint: endpoint}, _}, 2_000
      assert is_integer(d)
      assert endpoint == "http://127.0.0.1:#{port}"
      assert OcelForwarder.delivered_count() == before + 1
    end

    test "a 503 is counted, emitted as :failed, logged without credentials or body, and the log is rate-limited" do
      set_ingest_status(503)
      ref = probe([[:ash_a2a, :ocel, :failed]])
      Logger.metadata(ash_a2a_command_id: "corr-1")
      on_exit(fn -> Logger.metadata(ash_a2a_command_id: nil) end)

      Application.put_env(:ash_a2a, :ocel_log_interval_ms, 0)
      before = OcelForwarder.failed_count()

      log =
        capture_log(fn ->
          emit_dispatch_stop()
          assert_receive {^ref, _, %{duration: _}, meta, task_md}, 2_000
          assert meta.status == 503
          assert meta.reason == :non_2xx
          refute meta.endpoint =~ "s3cr3t"
          # OBS-12: the POST task inherited the emitter's Logger metadata.
          assert task_md[:ash_a2a_command_id] == "corr-1"
          # barrier: Logger processes everything emitted so far before capture_log returns
          Logger.flush()
        end)

      assert OcelForwarder.failed_count() == before + 1
      assert log =~ "non-2xx status 503"
      refute log =~ "s3cr3t-token"
      refute log =~ "secret-response-body"

      # Rate limit: a long interval suppresses the next three warnings...
      Application.put_env(:ash_a2a, :ocel_log_interval_ms, 3_600_000)

      suppressed_log =
        capture_log(fn ->
          for _ <- 1..3, do: emit_dispatch_stop()
          for _ <- 1..3, do: assert_receive({^ref, _, _, _, _}, 2_000)
          # barrier: Logger processes everything emitted so far before capture_log returns
          Logger.flush()
        end)

      refute suppressed_log =~ "OcelForwarder"
      assert OcelForwarder.failed_count() == before + 4

      # ...and the next emitted warning reports how many were suppressed.
      Application.put_env(:ash_a2a, :ocel_log_interval_ms, 0)

      next_log =
        capture_log(fn ->
          emit_dispatch_stop()
          assert_receive {^ref, _, _, _, _}, 2_000
          # barrier: Logger processes everything emitted so far before capture_log returns
          Logger.flush()
        end)

      assert next_log =~ "(3 similar warnings suppressed)"
    end

    test "a transport failure (connection refused) is counted and emitted as :failed" do
      ref = probe([[:ash_a2a, :ocel, :failed]])
      Application.put_env(:ash_a2a, :ocel_ingest_url, "http://u:p@127.0.0.1:1")
      Application.put_env(:ash_a2a, :ocel_log_interval_ms, 3_600_000)
      before = OcelForwarder.failed_count()

      capture_log(fn ->
        emit_dispatch_stop()
        assert_receive {^ref, _, _, %{status: nil, reason: reason, endpoint: ep}, _}, 5_000
        assert is_atom(reason)
        assert ep == "http://127.0.0.1:1"
      end)

      assert OcelForwarder.failed_count() == before + 1
    end

    test "shed metadata carries a sanitized :endpoint, never the raw :url" do
      ref = probe([[:ash_a2a, :ocel, :shed]])
      Application.put_env(:ash_a2a, :ocel_task_supervisor, :no_such_obs_task_supervisor)
      emit_dispatch_stop()
      assert_receive {^ref, _, %{count: 1}, meta, _}, 1_000
      refute Map.has_key?(meta, :url)
      refute meta.endpoint =~ "s3cr3t"
    end
  end

  describe "OBS-05: dispatch exceptions reach OCEL" do
    test "the forwarder is attached to [:ash_a2a, :dispatch, :exception]" do
      assert Enum.any?(
               :telemetry.list_handlers([:ash_a2a, :dispatch, :exception]),
               &(&1.id == {OcelForwarder, :dispatch_exception})
             )
    end

    test "an exception event is forwarded as <type>.exception with a redacted error code and no stacktrace" do
      :telemetry.execute(
        [:ash_a2a, :dispatch, :exception],
        %{duration: 42},
        %{
          resource_or_domain: AshA2A.Test.Fixture.Item,
          skill_name: "obs_probe",
          kind: :error,
          reason: %RuntimeError{message: "token=abc123"},
          stacktrace: [{__MODULE__, :f, 0, [file: ~c"secret_path.ex", line: 1]}]
        }
      )

      assert_receive {:ingested, [event]}, 2_000
      assert String.ends_with?(event["event_type"], ".obs_probe.exception")
      assert event["attributes"]["kind"] == "error"
      assert event["attributes"]["error_code"] == "exception:RuntimeError"
      assert event["attributes"]["duration_native"] == "42"
      body = Jason.encode!(event)
      refute body =~ "abc123"
      refute body =~ "secret_path"
    end
  end
end

# ------------------------------------------------------------------------------
# SECTION 5: Original test/ash_a2a/telemetry/ocel_boot_warning_test.exs
# ------------------------------------------------------------------------------

defmodule AshA2A.Telemetry.OcelBootWarningTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias AshA2A.Telemetry.OcelForwarder

  setup do
    prev = Application.get_env(:ash_a2a, :ocel_ingest_url)
    on_exit(fn -> Application.put_env(:ash_a2a, :ocel_ingest_url, prev) end)
  end

  test "warns and returns :disabled without ingest url" do
    Application.delete_env(:ash_a2a, :ocel_ingest_url)
    log = capture_log(fn -> assert OcelForwarder.warn_if_unconfigured() == :disabled end)
    assert log =~ "ASH_A2A_OCEL_INGEST_URL"
  end

  test "silent when configured" do
    Application.put_env(:ash_a2a, :ocel_ingest_url, "http://127.0.0.1:1")
    log = capture_log(fn -> assert OcelForwarder.warn_if_unconfigured() == :ok end)
    refute log =~ "no :ocel_ingest_url"
  end

  test "catch-all increments ignored counter" do
    before = OcelForwarder.ignored_count()
    assert :ok = OcelForwarder.handle_event([:other, :event], %{}, %{}, nil)
    assert OcelForwarder.ignored_count() == before + 1
  end

  describe "runtime.exs hook" do
    defp read_runtime(env_value) do
      prev = System.get_env("ASH_A2A_OCEL_INGEST_URL")

      if env_value,
        do: System.put_env("ASH_A2A_OCEL_INGEST_URL", env_value),
        else: System.delete_env("ASH_A2A_OCEL_INGEST_URL")

      try do
        Config.Reader.read!("config/runtime.exs", env: :test)
      after
        if prev,
          do: System.put_env("ASH_A2A_OCEL_INGEST_URL", prev),
          else: System.delete_env("ASH_A2A_OCEL_INGEST_URL")
      end
    end

    test "env var sets :ocel_ingest_url" do
      cfg = read_runtime("http://ocel.example:9/ingest")
      assert get_in(cfg, [:ash_a2a, :ocel_ingest_url]) == "http://ocel.example:9/ingest"
    end

    test "unset or empty env var leaves it unconfigured" do
      refute Keyword.has_key?(Keyword.get(read_runtime(nil), :ash_a2a, []), :ocel_ingest_url)
      refute Keyword.has_key?(Keyword.get(read_runtime(""), :ash_a2a, []), :ocel_ingest_url)
    end
  end

  test "boot sequence calls warn_if_unconfigured/0 after attach!/0 (structural pin)" do
    src = File.read!("lib/ash_a2a/application.ex")

    assert src =~
             ~r/OcelForwarder\.attach!\(\)\s*\n\s*_ = AshA2A\.Telemetry\.OcelForwarder\.warn_if_unconfigured\(\)/
  end
end

# ------------------------------------------------------------------------------
# SECTION 6: Original test/ash_a2a/telemetry/ocel_dispatch_parity_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.OcelDispatchParityTest do
  @moduledoc """
  The forwarder (HTTP) and the broadcaster (SIEM) must emit the SAME dispatch
  event for the same telemetry: both are built by
  `AshA2A.Telemetry.DispatchEvent`. Real telemetry -> two real sinks (a real
  Bandit forwarder ingest and a real Bandit Chronicle receiver) -> compare
  the wire bodies (modulo `event_id`/`event_time`). Also pins the forwarder's
  handler hygiene: a hostile metadata shape neither raises nor detaches it,
  and a stale CommandBus dispatch stash is never merged into an unrelated
  receipt.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Telemetry.{DispatchEvent, OcelBroadcaster, OcelForwarder}

  @resource AshA2A.Test.Fixture.FreedomGym.Facilitator
  @store AshA2A.Telemetry.OcelDispatchParityTest.Store

  defmodule Receiver do
    @moduledoc false
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    # forwarder ingest (JSON {"events": [...]}) and Chronicle (ndjson) in one
    post "/ocel/events" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"events" => events} = Jason.decode!(body)
      Agent.update(AshA2A.Telemetry.OcelDispatchParityTest.Store, &(&1 ++ [{:http, events}]))
      Plug.Conn.send_resp(conn, 201, "{}")
    end

    post "/v2/logs" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      events =
        body |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.map(&Jason.decode!/1)

      Agent.update(AshA2A.Telemetry.OcelDispatchParityTest.Store, &(&1 ++ [{:siem, events}]))
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    match(_) do
      Plug.Conn.send_resp(conn, 404, "no")
    end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: @store)
    %{base_url: base_url, pid: pid} = AshA2A.Test.EphemeralHttp.start!(Receiver)
    Application.put_env(:ash_a2a, :ocel_ingest_url, base_url)
    :ok = OcelForwarder.attach!()

    name = :"ocel_parity_#{System.unique_integer([:positive])}"

    start_supervised!(
      {OcelBroadcaster,
       name: name,
       endpoints: [[platform: :chronicle, endpoint: base_url, api_key: "k", max_retries: 0]],
       flush_interval_ms: false}
    )

    on_exit(fn ->
      Process.exit(pid, :normal)
      OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
      Application.delete_env(:ash_a2a, :ocel_pending_dispatch_ttl_ms)
    end)

    {:ok, bc: name}
  end

  # The one bounded poll: a deadline, not an iteration count.
  defp poll(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(10)
          poll(fun, deadline)
        end

      result ->
        result
    end
  end

  defp wire(kind) do
    poll(fn ->
      case for {^kind, evs} <- Agent.get(@store, & &1), do: evs do
        [] -> nil
        lists -> List.flatten(lists)
      end
    end)
  end

  defp normalise(event), do: Map.drop(event, ["event_id", "event_time"])

  defp parity!(bc, event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)

    assert :ok = OcelBroadcaster.flush(bc)
    [http] = wire(:http)
    [siem] = wire(:siem)

    assert normalise(http) == normalise(siem)
    assert http["event_time"] && siem["event_time"]
    http
  end

  test "dispatch stop with stage/error: identical attributes on both sinks", %{bc: bc} do
    event =
      parity!(bc, [:ash_a2a, :dispatch, :stop], %{duration: 77}, %{
        resource_or_domain: @resource,
        skill_name: :run_phase,
        stage: :skill_lookup,
        error: %{kind: :unknown_skill},
        object_id: "obj-1"
      })

    assert event["attributes"]["stage"] == "skill_lookup"
    assert event["attributes"]["error"] == "unknown_skill"
    assert event["relationships"] == [%{"qualifier" => "acted_on", "object_id" => "obj-1"}]
  end

  test "dispatch exception: identical kind/error_code form on both sinks", %{bc: bc} do
    event =
      parity!(bc, [:ash_a2a, :dispatch, :exception], %{duration: 5}, %{
        resource_or_domain: @resource,
        skill_name: :run_phase,
        kind: :error,
        reason: %RuntimeError{message: "secret"},
        stacktrace: []
      })

    assert event["event_type"] =~ ".exception"
    assert event["attributes"]["error_code"] == "exception:RuntimeError"
    refute inspect(event) =~ "secret"
  end

  test "DispatchEvent.event_type/1 is total over hostile metadata" do
    assert is_binary(DispatchEvent.event_type(%{}))
    assert is_binary(DispatchEvent.event_type(%{resource_or_domain: "str", skill_name: {:a, :b}}))
    assert is_binary(DispatchEvent.event_type(%{resource_or_domain: 42, skill_name: nil}))
    assert is_binary(DispatchEvent.event_type(:not_a_map))
  end

  test "the forwarder handler survives hostile metadata and stays attached" do
    :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, %{
      resource_or_domain: "not-a-resource",
      skill_name: %{weird: true}
    })

    :telemetry.execute([:ash_a2a, :dispatch, :exception], %{}, %{resource_or_domain: 7})
    :telemetry.execute([:ash_a2a, :dispatch, :stop], %{}, %{})

    attached =
      for h <- :telemetry.list_handlers([:ash_a2a, :dispatch]),
          match?({OcelForwarder, _}, h.id),
          do: h.id

    assert length(attached) == 2
    assert [_ | _] = wire(:http)
  end

  test "unconvertible receipt metadata is counted by the forwarder" do
    before_count = OcelForwarder.unconvertible_count()
    :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: :nope})
    :telemetry.execute([:ash_a2a, :receipt, :outboxed], %{}, %{})
    assert OcelForwarder.unconvertible_count() == before_count + 2
  end

  describe "pending dispatch stash" do
    defp receipt(command_id) do
      command =
        AshA2A.Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: command_id,
          agent_id: "agent-1",
          principal_id: "principal-1"
        )

      AshA2A.Receipt.from_reply(
        command,
        AshA2A.Identity.execution("exec-#{command_id}"),
        :observe,
        {:reply, []}
      )
    end

    defp stash_dispatch(extra) do
      Process.put(:ash_a2a_ocel_command_bus_dispatch, true)

      :telemetry.execute(
        [:ash_a2a, :dispatch, :stop],
        %{duration: 9},
        Map.merge(
          %{resource_or_domain: @resource, skill_name: :run_phase, reply_type: :reply},
          extra
        )
      )

      Process.delete(:ash_a2a_ocel_command_bus_dispatch)
    end

    test "a fresh stash for the same command merges into the receipt event" do
      stash_dispatch(%{command_id: "cmd-fresh", object_id: "obj-9"})
      :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: receipt("cmd-fresh")})

      [event] = wire(:http)
      assert event["attributes"]["skill_name"] == "run_phase"
      assert event["relationships"] == [%{"qualifier" => "acted_on", "object_id" => "obj-9"}]
    end

    test "a stale stash (past the TTL) is discarded, not merged into an unrelated receipt" do
      # A negative TTL makes every stash stale at consumption time.
      Application.put_env(:ash_a2a, :ocel_pending_dispatch_ttl_ms, -1)
      stash_dispatch(%{object_id: "stale-obj"})

      :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{
        receipt: receipt("cmd-unrelated")
      })

      [event] = wire(:http)
      refute Map.has_key?(event["attributes"], "skill_name")
      assert event["relationships"] == []
      # and the stash is cleared
      assert Process.get(:ash_a2a_ocel_pending_dispatch) == nil
    end

    test "a stash for a DIFFERENT command is discarded" do
      stash_dispatch(%{command_id: "cmd-A", object_id: "obj-A"})
      :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: receipt("cmd-B")})

      [event] = wire(:http)
      refute Map.has_key?(event["attributes"], "skill_name")
      assert Process.get(:ash_a2a_ocel_pending_dispatch) == nil
    end

    test "a direct dispatch clears a leftover stash" do
      stash_dispatch(%{object_id: "leftover"})
      assert Process.get(:ash_a2a_ocel_pending_dispatch)

      :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, %{
        resource_or_domain: @resource,
        skill_name: :run_phase
      })

      assert Process.get(:ash_a2a_ocel_pending_dispatch) == nil
    end
  end
end

# ------------------------------------------------------------------------------
# SECTION 7: Original test/ash_a2a/telemetry/ocel_forwarder_egress_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.OcelForwarderEgressTest do
  @moduledoc """
  CWE-918 court: the OCEL forwarder must not connect to loopback / link-local /
  metadata endpoints under the strict default policy. Oracle: a real local TCP
  listener that records whether any connection arrives (independent of the code
  under test). DB-free.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Telemetry.OcelForwarder

  setup do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    parent = self()

    acceptor =
      spawn_link(fn ->
        case :gen_tcp.accept(listen, 1_500) do
          {:ok, sock} ->
            data =
              case :gen_tcp.recv(sock, 0, 500) do
                {:ok, d} -> d
                _ -> ""
              end

            :gen_tcp.send(
              sock,
              "HTTP/1.1 201 Created\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )

            :gen_tcp.close(sock)
            send(parent, {:accepted, data})

          {:error, :timeout} ->
            send(parent, :nothing_accepted)
        end
      end)

    prev_policy = Application.fetch_env(:ash_a2a, :ocel_egress_policy)
    :ok = OcelForwarder.attach!()

    on_exit(fn ->
      OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)

      case prev_policy do
        {:ok, v} -> Application.put_env(:ash_a2a, :ocel_egress_policy, v)
        :error -> Application.delete_env(:ash_a2a, :ocel_egress_policy)
      end

      :gen_tcp.close(listen)
    end)

    {:ok, port: port, acceptor: acceptor}
  end

  defp fire do
    :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, %{
      resource_or_domain: EgressCourtDomain,
      skill_name: :probe,
      reply_type: :reply
    })
  end

  defp wait_failed(reason) do
    receive do
      {:ocel_failed, %{reason: ^reason}} -> :ok
      {:ocel_failed, other} -> flunk("unexpected failure metadata #{inspect(other)}")
    after
      2_000 -> flunk("no ocel failed event for #{inspect(reason)}")
    end
  end

  defp capture_failed do
    parent = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:ash_a2a, :ocel, :failed],
      fn _e, _m, meta, _ -> send(parent, {:ocel_failed, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "strict policy: loopback ingest URL is refused and the listener receives nothing", %{
    port: port
  } do
    Application.put_env(:ash_a2a, :ocel_egress_policy, [])
    Application.put_env(:ash_a2a, :ocel_ingest_url, "https://127.0.0.1:#{port}")
    capture_failed()
    fire()
    wait_failed(:refused_webhook_private_address)
    assert_receive :nothing_accepted, 3_000
    refute_received {:accepted, _}
  end

  test "strict policy: plain http to a public-looking host is refused by scheme" do
    Application.put_env(:ash_a2a, :ocel_egress_policy, [])
    Application.put_env(:ash_a2a, :ocel_ingest_url, "http://93.184.216.34:9")
    capture_failed()
    fire()
    wait_failed(:refused_webhook_scheme)
  end

  test "strict policy: 169.254.169.254 metadata literal is refused before any connect" do
    Application.put_env(:ash_a2a, :ocel_egress_policy, [])
    Application.put_env(:ash_a2a, :ocel_ingest_url, "https://169.254.169.254")
    capture_failed()
    fire()
    wait_failed(:refused_webhook_private_address)
  end

  test "policy admission is synchronous: EndpointPolicy refuses without connecting" do
    assert {:error, :refused_webhook_private_address, _} =
             AshA2A.Egress.EndpointPolicy.admit("https://169.254.169.254/x")

    assert {:error, :refused_webhook_private_address, _} =
             AshA2A.Egress.EndpointPolicy.admit("https://[::1]:8443")
  end

  test "positive control: explicit loopback allowance delivers, pinned with original Host header",
       %{port: port} do
    Application.put_env(:ash_a2a, :ocel_egress_policy,
      allow_http: true,
      allow_cidrs: ["127.0.0.0/8", "::1/128"]
    )

    Application.put_env(:ash_a2a, :ocel_ingest_url, "http://localhost:#{port}")
    fire()
    assert_receive {:accepted, data}, 3_000
    assert data =~ "POST /ocel/events"
    assert data =~ "host: localhost:#{port}"
  end
end

# ------------------------------------------------------------------------------
# SECTION 8: Original test/ash_a2a/telemetry/redact_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.RedactTest do
  use ExUnit.Case, async: true

  alias AshA2A.Telemetry.Redact

  doctest AshA2A.Telemetry.Redact

  test "summaries never carry the data of the reason term" do
    secret = "Bearer eyJsecret"

    reasons = [
      {:invalid_input, %{password: secret}},
      %{code: :dispatch_crashed, detail: secret},
      {:error, secret, :extra},
      %ArgumentError{message: secret},
      [secret],
      secret
    ]

    for reason <- reasons do
      summary = Redact.error_summary(reason)
      assert is_atom(summary.kind)
      refute inspect(summary) =~ "eyJsecret"
    end
  end

  test "actor_id/1 returns the id and never the struct" do
    assert Redact.actor_id(%{id: "a1", api_key: "k"}) == "a1"
    assert Redact.actor_id(%{principal: %{value: "p1"}}) == "p1"
    assert Redact.actor_id(%{api_key: "k"}) == nil
  end
end

# ------------------------------------------------------------------------------
# SECTION 9: Original test/ash_a2a/telemetry/router_counters_isolation_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.RouterCountersIsolationTest do
  @moduledoc """
  Real same-node caller-isolation coverage for
  `AshA2A.Telemetry.RouterCounters` (ticket b4p-f5-02 item 3).

  The stress wave (`test/ash_a2a/chicago/stress/multinode_concurrency_test.exs`,
  "Real defect found and deliberately not re-triggered") proved for real that
  two RouterCounters instances attached at once on one node cross-contaminate:
  `:telemetry.execute/3` broadcasts `[:ash_a2a, :router, :tier_selected]` to
  EVERY attached handler, so each instance's counts included the OTHER
  instance's dispatches, and an earlier draft of that file's per-batch exact
  counts assertion failed reproducibly
  (`batch 1/1 counts %{deterministic: 3, llm: 0, phrase: 1} do not exactly
  match the 2 facts-tier / 1 phrase-tier dispatches it drove`). That file
  pruned the concurrent-batch design to stay green; this file is the fix's
  own coverage: two concurrently-running router drivers, each with its own
  attached instance, asserting genuinely DISJOINT telemetry.

  The isolation mechanism is `attach!/3`'s `:owner` option -- the same
  design, semantics, and rationale `AshA2A.Telemetry.AllocationCounters`
  already shipped for the identical broadcast problem: `:any` (default)
  counts every emitter (the long-lived production instrument), a pid counts
  only events emitted by that process (a caller that attaches and routes in
  the same process owns a genuinely private measurement). A per-instance
  event-metadata token was considered and rejected: `route/3` would have to
  thread caller identity through its emitted metadata and opts, a wider
  public-API change with no in-repo precedent, while `:owner` closes the
  observed defect with the established pattern.

  `async: false` for the same reason `request_router_telemetry_test.exs`
  is: exact counts asserted against a real, global `:telemetry` event name;
  ExUnit's serial `async: false` phase is what makes "no other module's
  `route/3` fires into these handlers mid-assertion" a guarantee. The
  concurrency inside each test is this file's own `Task.async` drivers.

  Real collaborators throughout, zero mocks: real `:telemetry` attachment,
  real `RequestRouter.route/3` through the real deterministic solver
  (facts tier, `native/hddl_cli`) and the real caller-registered phrase
  template (phrase tier, zero LLM).
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Planning.RequestRouter
  alias AshA2A.Telemetry.RouterCounters
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  @phrase_regex ~r/^create a labeled item$/

  # Deliberate fallback, not sloppiness: on code WITHOUT `attach!/3`, this
  # degrades to the unscoped `attach!/1` so the exact-count assertions below
  # fail with the REAL contamination numbers (each ref inflated by the other
  # driver's dispatches) instead of an UndefinedFunctionError. The fail-before
  # run of this file is therefore a demonstration of the defect itself, not a
  # missing-API crash.
  defp attach_scoped!(ref) do
    if function_exported?(RouterCounters, :attach!, 3) do
      RouterCounters.attach!(ref, make_ref(), owner: self())
    else
      RouterCounters.attach!(ref)
    end
  end

  describe "per-pid instance isolation under same-node concurrency" do
    test "two concurrently-running router drivers' instances observe disjoint telemetry" do
      driver = fn driver_idx ->
        ref = RouterCounters.new()
        handler_id = attach_scoped!(ref)

        try do
          Enum.each(1..2, fn _ -> assert {:ok, _} = route_facts_tier!(driver_idx) end)
          assert {:ok, _} = route_phrase_tier!()

          RouterCounters.counts(ref)
        after
          RouterCounters.detach(handler_id)
        end
      end

      # Both drivers run genuinely concurrently, each attaching its own
      # instance first -- the exact shape the stress wave had to prune.
      task_a = Task.async(fn -> driver.(:a) end)
      task_b = Task.async(fn -> driver.(:b) end)
      counts_a = Task.await(task_a, 60_000)
      counts_b = Task.await(task_b, 60_000)

      # The assertion the stress wave could not make: each instance's counts
      # are EXACTLY its own dispatches (2 facts + 1 phrase) -- never the
      # union of both drivers' (which would read deterministic: 4, phrase: 2).
      assert counts_a == %{deterministic: 2, llm: 0, phrase: 1}
      assert counts_b == %{deterministic: 2, llm: 0, phrase: 1}
    end

    test "a pid-scoped instance never observes another process's dispatches" do
      ref = RouterCounters.new()
      handler_id = attach_scoped!(ref)

      try do
        # Another process routes; this instance must stay at zero.
        other = Task.async(fn -> assert {:ok, _} = route_facts_tier!(:other) end)
        Task.await(other, 60_000)

        assert RouterCounters.counts(ref) == %{deterministic: 0, llm: 0, phrase: 0}

        # This process routes; now the instance counts exactly its own.
        assert {:ok, _} = route_facts_tier!(:self)
        assert RouterCounters.counts(ref) == %{deterministic: 1, llm: 0, phrase: 0}
      after
        RouterCounters.detach(handler_id)
      end
    end

    test "the default (:any) scope keeps the long-lived instrument counting every emitter" do
      ref = RouterCounters.new()
      handler_id = RouterCounters.attach!(ref)

      try do
        other = Task.async(fn -> assert {:ok, _} = route_facts_tier!(:other_any) end)
        Task.await(other, 60_000)

        assert RouterCounters.counts(ref) == %{deterministic: 1, llm: 0, phrase: 0}
      after
        RouterCounters.detach(handler_id)
      end
    end
  end

  defp route_facts_tier!(driver_idx) do
    RequestRouter.route(HddlDeterministicFixture, facts_message(driver_idx))
  end

  defp facts_message(driver_idx) do
    AshA2A.Protocol.Message.new_user([
      AshA2A.Protocol.Part.Data.new(%{"goal_facts" => goal_facts_envelope(driver_idx)})
    ])
  end

  defp goal_facts_envelope(driver_idx) do
    %{
      "request_id" =>
        "router-counters-isolation-#{driver_idx}-#{System.unique_integer([:positive])}",
      "domain_name" => "router-counters-isolation-domain",
      "problem_name" => "router-counters-isolation-problem",
      "objects" => ["on", "off"],
      "init" => [%{"predicate" => "current_phase", "args" => ["on"]}],
      "goal" => [
        %{"predicate" => "current_phase", "args" => ["off"]},
        %{"predicate" => "has_key", "args" => ["off"]}
      ],
      "task_sequence" => [
        %{"capability_id" => @advance_id, "args" => ["on", "off"]},
        %{"capability_id" => @unlock_id, "args" => ["off"]}
      ]
    }
  end

  defp route_phrase_tier! do
    RequestRouter.route(
      HddlDeterministicFixture,
      AshA2A.Protocol.Message.new_user("create a labeled item"),
      phrase_templates: [phrase_template()]
    )
  end

  defp phrase_template do
    %{regex: @phrase_regex, to_envelope: fn _captures -> goal_facts_envelope(:phrase) end}
  end
end

# ------------------------------------------------------------------------------
# SECTION 10: Original test/pm4exunit/multi_agent_pm4_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MultiAgentPm4Test.IntakeResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.IntakeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.IntakeDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.IntakeResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.IntakeAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.IntakeResource,
    name: "multi_agent_pm4_intake"
end

defmodule AshA2A.MultiAgentPm4Test.ReviewResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.ReviewDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.ReviewDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.ReviewResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.ReviewAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.ReviewResource,
    name: "multi_agent_pm4_review"
end

defmodule AshA2A.MultiAgentPm4Test.FulfilResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.FulfilDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.FulfilDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.FulfilResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.FulfilAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.FulfilResource,
    name: "multi_agent_pm4_fulfil"
end

defmodule AshA2A.MultiAgentPm4Test do
  @moduledoc """
  Process-conformance of three real `AshA2A.Agent`s (intake, review, fulfil)
  interacting over real HTTP+JSON (Bandit loopback, `AshA2A.Protocol.Client`).
  Events are emitted only from observed outcomes of real client calls: the task
  ids and states come back from the remote agents, and the cross-agent hand-off
  is driven by those returned ids.

  ash_a2a also ships an ash_pplan-backed durability adapter (`adapter: :pplan`
  behind the `TaskStore` seam); ash_pplan is a test-only dependency here.
  """
  use ExUnit.Case, async: false
  use Pm4ExUnit

  @moduletag :pm4exunit
  @moduletag :serial_shard

  alias AshA2A.Protocol.{Client, Task}
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}
  alias AshA2A.Transport.HTTPJSON, as: Binding

  @agents %{
    intake: AshA2A.MultiAgentPm4Test.IntakeAgent,
    review: AshA2A.MultiAgentPm4Test.ReviewAgent,
    fulfil: AshA2A.MultiAgentPm4Test.FulfilAgent
  }

  setup do
    {_sup, _reg} =
      AgentSupervisorCase.start_supervised_agents!(__MODULE__, Map.values(@agents))

    clients =
      Map.new(@agents, fn {role, agent} ->
        server =
          EphemeralHttp.start!(
            {Binding, Binding.init(agent: agent, base_url: "http://127.0.0.1/#{role}")}
          )

        {role, {server.base_url, Client.new(server.base_url, transport: :http_json)}}
      end)

    urls = Map.new(clients, fn {r, {u, _}} -> {r, u} end)
    clients = Map.new(clients, fn {r, {_, cl}} -> {r, cl} end)
    %{clients: clients, urls: urls}
  end

  defp ev(session, activity, attrs) do
    emit_event(session, "e#{System.unique_integer([:positive, :monotonic])}", activity, attrs)
  end

  # One real hop: call the agent, emit the event only from the returned task.
  defp hop(session, client, activity, text, opts \\ []) do
    assert {:ok, %Task{} = task} = Client.send_message(client, text, opts)
    assert task.status.state == :completed
    ev(session, activity, resource: task.id)
    task
  end

  test "intake -> review -> fulfil hand-off, each hop a distinct real task", %{
    pm4_session: session,
    clients: c
  } do
    t1 = hop(session, c.intake, :intake_done, "new order")
    t2 = hop(session, c.review, :review_done, "review #{t1.id}")
    t3 = hop(session, c.fulfil, :fulfil_done, "fulfil #{t2.id}")

    assert length(Enum.uniq([t1.id, t2.id, t3.id])) == 3

    # Each agent owns its task: foreign agents do not know the other's task id.
    assert {:ok, %Task{id: id}} = Client.get_task(c.intake, t1.id)
    assert id == t1.id
    assert {:error, _} = Client.get_task(c.review, t1.id)

    assert_conformance(session, [[:intake_done, :review_done, :fulfil_done]], min_fitness: 1.0)
  end

  test "skipping review violates the hand-off model", %{pm4_session: session, clients: c} do
    hop(session, c.intake, :intake_done, "new order")
    hop(session, c.fulfil, :fulfil_done, "fulfil without review")

    refute_conformance(session, [[:intake_done, :review_done, :fulfil_done]], min_fitness: 1.0)
  end

  test "three agents served concurrently each complete exactly their own task", %{
    pm4_session: session,
    clients: c
  } do
    results =
      [intake: :intake_done, review: :review_done, fulfil: :fulfil_done]
      |> Elixir.Task.async_stream(
        fn {role, activity} ->
          {:ok, %Task{} = t} = Client.send_message(Map.fetch!(c, role), "parallel #{role}")
          {activity, t}
        end,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, fn {_a, t} -> t.status.state == :completed end)
    assert length(Enum.uniq(Enum.map(results, fn {_a, t} -> t.id end))) == 3

    for {activity, t} <- results, do: ev(session, activity, resource: t.id)

    # Concurrent arrival order is unconstrained: any permutation of the three is lawful.
    perms =
      for a <- [:intake_done, :review_done, :fulfil_done],
          b <- [:intake_done, :review_done, :fulfil_done] -- [a],
          cc <- [:intake_done, :review_done, :fulfil_done] -- [a, b],
          do: [a, b, cc]

    assert_conformance(session, perms)
  end

  test "agent cards are distinct per agent", %{urls: urls} do
    names =
      for {_role, url} <- urls do
        {:ok, card} = Client.discover(url)
        card.name
      end

    assert length(Enum.uniq(names)) == 3
  end
end

# ------------------------------------------------------------------------------
# SECTION 11: Original test/pm4exunit/planned_agents_pm4_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PlannedAgentsPm4Test do
  @moduledoc """
  Plan-driven multi-agent interaction, no LLM and no hard-coded hand-off.

  An `AshPPlan.FOND` domain models an order lifecycle; `Synthesis.synthesize/3`
  yields a strong-cyclic policy (state -> action). A runner executes the policy:
  each action is a real A2A call over HTTP+JSON, and the next state is the
  observed `Task` state of the reply (completed -> approved, failed ->
  rejected). The environment's nondeterminism is real: the reviewer role is
  served by an open agent (completes) or a forbidding agent (task fails).
  Conformance paths come from the same FOND domain + policy, with visit-ordinal
  labels (pm4 token replay cannot match repeated labels).
  """
  use ExUnit.Case, async: false
  use Pm4ExUnit

  @moduletag :pm4exunit
  @moduletag :serial_shard

  alias AshA2A.Protocol.{Client, Task}
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}
  alias AshA2A.Transport.HTTPJSON, as: Binding
  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis

  @initial :new
  @max_steps 12
  @max_visits 3

  @agents %{
    intake: AshA2A.MultiAgentPm4Test.IntakeAgent,
    approve: AshA2A.MultiAgentPm4Test.ReviewAgent,
    deny: AshA2A.Test.Fixture.LockedAgent,
    fulfil: AshA2A.MultiAgentPm4Test.FulfilAgent
  }

  # action -> role that serves it ( :review picks approve|deny per environment ).
  @binding %{submit: :intake, review: :reviewer, revise: :intake, ship: :fulfil}

  defp domain! do
    {:ok, d} =
      FOND.new(
        %{
          new: %{submit: [:submitted]},
          submitted: %{review: [:approved, :rejected]},
          rejected: %{revise: [:submitted]},
          approved: %{ship: [:shipped]},
          shipped: %{}
        },
        [:shipped]
      )

    d
  end

  defp policy!(d) do
    {:ok, p} = Synthesis.synthesize(d, @initial, :strong_cyclic)
    assert {:ok, _} = FOND.validate_policy(d, p, @initial, :strong_cyclic)
    p
  end

  defp label(from, action, to, n), do: "#{from}.#{action}->#{to}##{n}"

  # Model: every policy path to a goal, each source state visited <= @max_visits times.
  defp model_paths(d, p, state \\ @initial, visits \\ %{}, acc \\ []) do
    cond do
      MapSet.member?(d.goals, state) ->
        [Enum.reverse(acc)]

      Map.get(visits, state, 0) >= @max_visits ->
        []

      true ->
        action = Map.fetch!(p, state)
        n = Map.get(visits, state, 0)
        visits = Map.put(visits, state, n + 1)

        Enum.flat_map(FOND.outcomes(d, state, action), fn to ->
          model_paths(d, p, to, visits, [label(state, action, to, n) | acc])
        end)
    end
  end

  setup do
    {_sup, _reg} = AgentSupervisorCase.start_supervised_agents!(__MODULE__, Map.values(@agents))

    clients =
      Map.new(@agents, fn {role, agent} ->
        server =
          EphemeralHttp.start!(
            {Binding, Binding.init(agent: agent, base_url: "http://127.0.0.1/#{role}")}
          )

        {role, Client.new(server.base_url, transport: :http_json)}
      end)

    %{clients: clients}
  end

  # Observed task state -> FOND outcome for the action just executed.
  defp outcome(:submit, :completed), do: {:ok, :submitted}
  defp outcome(:revise, :completed), do: {:ok, :submitted}
  defp outcome(:review, :completed), do: {:ok, :approved}
  defp outcome(:review, :failed), do: {:ok, :rejected}
  defp outcome(:ship, :completed), do: {:ok, :shipped}
  defp outcome(_action, state), do: {:error, {:unmodeled_outcome, state}}

  # Policy runner. `reviewers` is the environment's per-visit reviewer verdict queue.
  defp run(session, clients, d, p, reviewers) do
    step(session, clients, d, p, @initial, reviewers, %{}, 0)
  end

  defp step(session, clients, d, p, state, reviewers, visits, count) do
    cond do
      MapSet.member?(d.goals, state) ->
        {:ok, state, count}

      count >= @max_steps ->
        {:error, :step_budget_exhausted}

      true ->
        action = Map.fetch!(p, state)

        with {:ok, role, rest} <- role_for(action, reviewers),
             {:ok, %Task{} = task} <- Client.send_message(Map.fetch!(clients, role), "#{action}"),
             {:ok, to} <- outcome(action, task.status.state),
             true <- to in FOND.outcomes(d, state, action) do
          n = Map.get(visits, state, 0)
          emit_event(session, "s#{count}", label(state, action, to, n), resource: task.id)
          step(session, clients, d, p, to, rest, Map.put(visits, state, n + 1), count + 1)
        else
          {:error, _} = e -> e
          false -> {:error, :outcome_outside_model}
        end
    end
  end

  defp role_for(:review, [verdict | rest]), do: {:ok, verdict, rest}
  defp role_for(:review, []), do: {:error, :environment_exhausted}
  defp role_for(action, reviewers), do: {:ok, Map.fetch!(@binding, action), reviewers}

  test "policy is strong-cyclic and its action table is exactly the plan", _ do
    d = domain!()
    p = policy!(d)

    assert p == %{new: :submit, submitted: :review, rejected: :revise, approved: :ship}
  end

  test "approve on first review: shortest plan, conforms", %{pm4_session: s, clients: c} do
    d = domain!()
    p = policy!(d)

    assert {:ok, :shipped, 3} = run(s, c, d, p, [:approve])
    assert_conformance(s, model_paths(d, p), min_fitness: 1.0)
  end

  for rejections <- 1..2 do
    test "#{rejections} rejection(s) then approval: retry branch reaches goal and conforms",
         %{pm4_session: s, clients: c} do
      d = domain!()
      p = policy!(d)
      verdicts = List.duplicate(:deny, unquote(rejections)) ++ [:approve]

      assert {:ok, :shipped, steps} = run(s, c, d, p, verdicts)
      assert steps == 3 + 2 * unquote(rejections)
      assert_conformance(s, model_paths(d, p), min_fitness: 1.0)
    end
  end

  test "every enumerated model path is realizable by some environment verdict sequence",
       %{clients: c} do
    d = domain!()
    p = policy!(d)
    paths = model_paths(d, p)
    assert length(paths) == @max_visits

    for path <- paths do
      rejections = Enum.count(path, &String.contains?(&1, "->rejected#"))
      {:ok, session} = Pm4ExUnit.Session.start_link(test_name: "realize-#{rejections}")
      verdicts = List.duplicate(:deny, rejections) ++ [:approve]
      assert {:ok, :shipped, _} = run(session, c, d, p, verdicts)
      assert_conformance(session, [path], min_fitness: 1.0)
    end
  end

  test "an environment that always rejects ends in a typed refusal, never a loop",
       %{pm4_session: s, clients: c} do
    d = domain!()
    p = policy!(d)

    assert {:error, :environment_exhausted} = run(s, c, d, p, [:deny, :deny])

    # The partial trace is a prefix of a lawful path but does not reach the goal.
    refute_conformance(s, model_paths(d, p), min_fitness: 1.0)
  end

  test "a hand-driven run that skips review violates the generated model",
       %{pm4_session: s, clients: c} do
    assert {:ok, %Task{}} = Client.send_message(c.intake, "submit")
    emit_event(s, "x0", label(:new, :submit, :submitted, 0))
    assert {:ok, %Task{}} = Client.send_message(c.fulfil, "ship")
    emit_event(s, "x1", label(:approved, :ship, :shipped, 0))

    d = domain!()
    refute_conformance(s, model_paths(d, policy!(d)), min_fitness: 1.0)
  end
end

# ------------------------------------------------------------------------------
# SECTION 12: Original test/semantic_work/admission_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.AdmissionTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Admission

  test "requires subject-bound input" do
    assert {:error, _} = Admission.bind(%{})
    assert {:error, :refused_invalid_envelope} = Admission.bind(nil)
  end
end

# ------------------------------------------------------------------------------
# SECTION 13: Original test/semantic_work/candidate_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.CandidateTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Candidate

  test "requires subject-bound input" do
    assert {:error, _} = Candidate.bind(%{})
    assert {:error, :refused_invalid_envelope} = Candidate.bind(nil)
  end
end

# ------------------------------------------------------------------------------
# SECTION 14: Original test/semantic_work/checkpoint_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.CheckpointTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Checkpoint

  test "fails closed" do
    assert {:error, _} = Checkpoint.bind(%{})
    assert {:error, :refused_invalid_envelope} = Checkpoint.bind(:invalid)
  end
end

# ------------------------------------------------------------------------------
# SECTION 15: Original test/semantic_work/envelope_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.EnvelopeTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Envelope

  test "fetches atom and string keys" do
    assert {:ok, %{a: 1, b: 2}} = Envelope.fetch(%{:a => 1, "b" => 2}, [:a, :b])
  end

  test "nil, empty string and false are missing, first missing key reported" do
    for bad <- [nil, "", false] do
      assert {:error, {:refused_missing_identity, :b}} =
               Envelope.fetch(%{a: 1, b: bad, c: nil}, [:a, :b, :c])
    end

    assert {:error, {:refused_missing_identity, :a}} = Envelope.fetch(%{}, [:a])
  end

  test "zero is present" do
    assert {:ok, %{a: 0}} = Envelope.fetch(%{a: 0}, [:a])
  end
end

# ------------------------------------------------------------------------------
# SECTION 16: Original test/semantic_work/graph_identity_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.GraphIdentityTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.GraphIdentity

  test "fails closed" do
    assert {:error, _} = GraphIdentity.bind(%{})
    assert {:error, :refused_invalid_envelope} = GraphIdentity.bind(:invalid)
  end
end

# ------------------------------------------------------------------------------
# SECTION 17: Original test/semantic_work/lease_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.LeaseTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Lease

  test "fails closed" do
    assert {:error, _} = Lease.bind(%{})
    assert {:error, :refused_invalid_envelope} = Lease.bind(:invalid)
  end

  test "accepts integer or DateTime expires_at" do
    now = DateTime.utc_now()
    assert {:ok, %{expires_at: 10}} = Lease.bind(%{lease_id: "l", subject: "s", expires_at: 10})

    assert {:ok, %{expires_at: ^now}} =
             Lease.bind(%{"lease_id" => "l", "subject" => "s", "expires_at" => now})
  end

  test "refuses other expires_at types" do
    for bad <- ["tomorrow", 1.5, :soon, %{}] do
      assert {:error, {:refused_invalid_lease, :expires_at}} =
               Lease.bind(%{lease_id: "l", subject: "s", expires_at: bad})
    end
  end
end

# ------------------------------------------------------------------------------
# SECTION 18: Original test/semantic_work/projection_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.ProjectionTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Projection

  test "refusal is typed" do
    assert {:error, {:refused_missing_identity, _}} = Projection.bind(%{})
  end
end

# ------------------------------------------------------------------------------
# SECTION 19: Original test/semantic_work/provider_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.ProviderTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Provider

  test "refusal is typed" do
    assert {:error, {:refused_missing_identity, _}} = Provider.bind(%{})
  end
end

# ------------------------------------------------------------------------------
# SECTION 20: Original test/semantic_work/work_order_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.WorkOrderTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.WorkOrder

  test "fails closed" do
    assert {:error, _} = WorkOrder.bind(%{})
    assert {:error, :refused_invalid_envelope} = WorkOrder.bind(:invalid)
  end
end

# ------------------------------------------------------------------------------
# SECTION 21: Original test/telemetry_bridge/pplan_hazard_bridge_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# SPDX-layer bridge court for `AshA2A.TelemetryBridge.PPlanHazard`.
# Chicago discipline: real collaborators. The live-twin assertions run the
# REAL `AshPPlan.Telemetry.Broadcaster` (test-only dep) and assert on the real
# `%{type: :hazard_tripped, data: %HazardTripped{}}` envelope; the MAD=0 path
# is exercised through the real zero-dispersion hazard payload of the same
# vocabulary. The pack
# vocabulary check grounds against the real latency-hazard-radar
# `ontology.ttl` when present on disk, and skips LOUDLY otherwise.

defmodule AshA2A.TelemetryBridge.PPlanHazardTest do
  use ExUnit.Case, async: true

  @moduletag :pplan_court

  alias AshA2A.Protocol.Task
  alias AshA2A.TelemetryBridge.PPlanHazard

  # Compile-time live-producer detection: ash_pplan 26.11.10 (Hex) ships the
  # AshPPlan.Telemetry surface (Event.HazardTripped + Broadcaster). If the
  # resolved ash_pplan lacks it, the live tests skip LOUD (never silently).
  pplan_ebin =
    Mix.Project.build_path()
    |> Path.join("lib/ash_pplan/ebin/Elixir.AshPPlan.Telemetry.Event.beam")

  scratch_ebin = System.get_env("I3_TELEMETRY_EBIN")

  pplan_scratch_beam =
    scratch_ebin && Path.join(scratch_ebin, "Elixir.AshPPlan.Telemetry.Event.beam")

  @live_producer File.regular?(pplan_ebin) or
                   (is_binary(pplan_scratch_beam) and File.regular?(pplan_scratch_beam))

  @live_skip_reason if(@live_producer,
                      do: false,
                      else:
                        "LOUD SKIP: AshPPlan.Telemetry.Event not in resolved ash_pplan (need >= 26.11.10)"
                    )

  if not @live_producer do
    IO.warn(
      "I3 LOUD SKIP: AshPPlan.Telemetry.Event not in the resolved ash_pplan " <>
        "(need ash_pplan >= 26.11.10 under MIX_ENV=test). Live tests skipped."
    )
  end

  @pack_ontology_candidates [
    "/Users/sac/ggen-marketplace/packs/latency-hazard-radar/ontology.ttl",
    "~/ggen-marketplace/packs/latency-hazard-radar/ontology.ttl"
  ]

  @pack_ontology_path Enum.find(@pack_ontology_candidates, fn p ->
                        match?({:ok, _}, File.read(Path.expand(p)))
                      end)

  if is_nil(@pack_ontology_path) do
    IO.warn(
      "LOUD SKIP: latency-hazard-radar ontology.ttl not found on disk; vocabulary test skipped."
    )
  end

  defp contract_event(overrides) do
    Map.merge(
      %{
        topic: "twin.partner.hazard",
        type: :hazard_tripped,
        run_id: "run-court-1",
        name: :partner_a,
        z: 3.1,
        threshold: 2.5,
        median: 105.0,
        mad: 7.0
      },
      Map.new(overrides)
    )
  end

  defp fresh_task, do: Task.new(id: "tsk-hazard-court")

  # Live-path helpers: all upstream calls are dynamic (apply) so the court
  # compiles cleanly under a Hex pin that predates the telemetry surface.
  defp live_mod(name), do: String.to_atom("Elixir.AshPPlan.Telemetry." <> name)

  defp hazard_struct(fields) when is_list(fields) do
    mod = live_mod("Event.HazardTripped")
    struct(mod, fields)
  end

  defp start_broadcaster(name) do
    mod = live_mod("Broadcaster")
    pid = start_supervised!({mod, [name: name]})
    {:ok, pid}
  end

  defp broadcaster_subscribe(server, topic) do
    apply(live_mod("Broadcaster"), :subscribe, [server, topic])
  end

  defp broadcaster_broadcast(server, topic, data) do
    apply(live_mod("Broadcaster"), :broadcast, [server, topic, data])
  end

  # --- (4) shared vocabulary vs the pack ontology ---------------------------

  describe "shared vocabulary with latency-hazard-radar ontology" do
    # A missing pack on disk is a LOUD skip (IO.warn above + skip reason),
    # never a silent pass and never an assertion failure of the pack's absence.
    @tag skip:
           if(is_nil(@pack_ontology_path),
             do: "LOUD SKIP: pack ontology.ttl not on disk",
             else: false
           )
    test "bridge defaults mirror the pack's pinned threshold and refusal atom" do
      source = File.read!(Path.expand(@pack_ontology_path))

      assert source =~ "urn:latency-hazard-radar:", "pack namespace declaration missing"

      # lhr:hazardThreshold default = 2.5 (lhr:default-policy individual)
      assert source =~ ~r/hazardThreshold "2\.5"/, "pack default hazardThreshold drifted from 2.5"

      # lhr:refusalAtom = insufficient_dispersion
      assert source =~ "insufficient_dispersion", "pack refusalAtom drifted"

      # vocabulary the bridge mirrors is still declared
      assert source =~ "triagePrompt"
      assert source =~ "medianMillis"
      assert source =~ "madMillis"
    end
  end

  # --- (3) trip / no-trip / refusal court -----------------------------------

  describe "trip law (strictly greater than threshold)" do
    test "z above threshold annotates the task metadata" do
      task = fresh_task()

      assert {:ok, annotated} = PPlanHazard.annotate(task, contract_event(z: 3.1, threshold: 2.5))
      assert annotated.metadata["hazard"] == "hazard: z=3.1, threshold=2.5"
      assert annotated.id == task.id
      assert annotated.status.state == :submitted
    end

    test "z below threshold returns the task unchanged (no annotation)" do
      task = fresh_task()

      assert {:ok, unchanged} = PPlanHazard.annotate(task, contract_event(z: 1.2, threshold: 2.5))
      assert unchanged == task
      assert unchanged.metadata == %{}
    end

    test "z exactly at threshold does NOT trip" do
      task = fresh_task()

      assert {:ok, unchanged} = PPlanHazard.annotate(task, contract_event(z: 2.5, threshold: 2.5))
      assert unchanged.metadata == %{}
    end

    test "integer z and threshold compare and format without float artifacts" do
      task = fresh_task()

      assert {:ok, annotated} = PPlanHazard.annotate(task, contract_event(z: 5, threshold: 3))
      assert annotated.metadata["hazard"] == "hazard: z=5, threshold=3"
    end

    test "annotation preserves pre-existing task metadata" do
      task = %{fresh_task() | metadata: %{"tenant" => "acme"}}

      assert {:ok, annotated} = PPlanHazard.annotate(task, contract_event(z: 4.0))
      assert annotated.metadata["tenant"] == "acme"
      assert annotated.metadata["hazard"] == "hazard: z=4.0, threshold=2.5"
    end
  end

  describe "malformed events are typed refusals" do
    test "non-number z, non-number threshold, nil z, non-number mad" do
      task = fresh_task()

      for bad <- [[z: "3"], [z: nil], [threshold: nil], [threshold: "2.5"], [mad: "7"]] do
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:refused, :invalid_event} = PPlanHazard.annotate(task, contract_event(bad))
        end)
      end

      assert {:refused, :invalid_event} =
               ExUnit.CaptureLog.with_log(fn -> PPlanHazard.annotate(task, %{}) end) |> elem(0)
    end

    test "missing :mad still annotates on trip (mad is optional)" do
      task = fresh_task()
      event = Map.delete(contract_event(z: 4.0), :mad)
      assert {:ok, annotated} = PPlanHazard.annotate(task, event)
      assert annotated.metadata["hazard"] == "hazard: z=4.0, threshold=2.5"
    end

    test "annotation tolerates nil task metadata and non-number format input" do
      task = %{fresh_task() | metadata: nil}
      assert {:ok, annotated} = PPlanHazard.annotate(task, contract_event(z: 4.0))
      assert annotated.metadata["hazard"] =~ "hazard: z=4.0"
      assert PPlanHazard.annotation(%{z: :weird}, 2.5) == "hazard: z=:weird, threshold=2.5"
    end
  end

  describe "MAD = 0 insufficient-dispersion refusal" do
    test "mad: 0 is a typed refusal, no annotation, typed log line" do
      task = fresh_task()
      event = contract_event(z: 99.0, mad: 0)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:refused, :insufficient_dispersion} = PPlanHazard.annotate(task, event)
        end)

      assert log =~ "insufficient_dispersion"
      assert task.metadata == %{}
    end

    test "explicit error field is also refused (typed path)" do
      task = fresh_task()
      event = contract_event(error: :insufficient_dispersion)

      assert {:refused, :insufficient_dispersion} = PPlanHazard.annotate(task, event)
      assert task.metadata == %{}
    end
  end

  # --- (1) live twin consumption --------------------------------------------

  describe "live AshPPlan.Telemetry.Broadcaster consumption" do
    @tag skip: @live_skip_reason
    test "real hazard envelope annotates with the live z and threshold" do
      {:ok, _pid} = start_broadcaster(:i3_broadcaster_a)
      topic = :i3_hazard_topic

      broadcaster_subscribe(:i3_broadcaster_a, topic)

      event_data =
        hazard_struct(
          run_id: "run-live-1",
          hazard: %{z: 3.1, threshold: 2.5, median: 105.0, mad: 7.0}
        )

      broadcaster_broadcast(:i3_broadcaster_a, topic, event_data)

      assert_receive {:ash_pplan_telemetry, envelope}, 2_000
      assert envelope.type == :hazard_tripped
      assert envelope.run_id == "run-live-1"
      assert envelope.data.hazard.z == 3.1

      contract = %{
        topic: envelope.topic,
        type: envelope.type,
        run_id: envelope.run_id,
        z: envelope.data.hazard.z,
        threshold: envelope.data.hazard.threshold,
        median: envelope.data.hazard.median,
        mad: envelope.data.hazard.mad
      }

      task = fresh_task()
      assert {:ok, annotated} = PPlanHazard.annotate(task, contract)
      assert annotated.metadata["hazard"] == "hazard: z=3.1, threshold=2.5"
    end

    @tag skip: @live_skip_reason
    test "envelope seq is monotonic per topic and stamped with emitted_at" do
      {:ok, _pid} = start_broadcaster(:i3_broadcaster_b)
      topic = :i3_seq_topic
      broadcaster_subscribe(:i3_broadcaster_b, topic)

      data = hazard_struct(run_id: "run-live-seq", hazard: %{z: 9.0, threshold: 2.5, mad: 1.0})
      broadcaster_broadcast(:i3_broadcaster_b, topic, data)
      broadcaster_broadcast(:i3_broadcaster_b, topic, data)

      assert_receive {:ash_pplan_telemetry, e1}, 2_000
      assert_receive {:ash_pplan_telemetry, e2}, 2_000
      assert e2.seq == e1.seq + 1
      assert %DateTime{} = e1.emitted_at
    end

    @tag skip: @live_skip_reason
    test "real zero-dispersion payload refuses with no annotation" do
      {:ok, _pid} = start_broadcaster(:i3_broadcaster_c)
      topic = :i3_flat_topic
      broadcaster_subscribe(:i3_broadcaster_c, topic)

      data =
        hazard_struct(
          run_id: "run-live-flat",
          hazard: %{z: 0.0, threshold: 2.5, median: 50.0, mad: 0}
        )

      broadcaster_broadcast(:i3_broadcaster_c, topic, data)
      assert_receive {:ash_pplan_telemetry, envelope}, 2_000
      assert envelope.type == :hazard_tripped

      contract = %{
        topic: envelope.topic,
        type: envelope.type,
        run_id: envelope.run_id,
        z: envelope.data.hazard.z,
        threshold: envelope.data.hazard.threshold,
        median: envelope.data.hazard.median,
        mad: envelope.data.hazard.mad
      }

      task = fresh_task()
      assert {:refused, :insufficient_dispersion} = PPlanHazard.annotate(task, contract)
      assert task.metadata == %{}
    end
  end
end

