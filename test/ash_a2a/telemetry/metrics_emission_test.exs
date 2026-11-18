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
