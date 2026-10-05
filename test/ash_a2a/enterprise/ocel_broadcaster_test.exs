# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.OcelBroadcasterCourtTest do
  @moduledoc """
  OCEL broadcaster court (PRD v26.10.4 §2 `:siem` gate child): Chicago courts
  over the REAL `AshA2A.Telemetry.OcelBroadcaster` — a real `:telemetry`
  emission, a real OCEL v2 conversion, a real bounded-queue overflow
  (drop-oldest with drop-counter telemetry), and a real flush captured by a
  real local Bandit SIEM receiver (the `test/ash_a2a/enterprise/siem_test.exs`
  technique: real Plug.Router + real Agent capture + real Req delivery).
  Zero mocks.

  Witnessed:

    * real telemetry emit → real OCEL v2 event buffered → `flush/1` → the
      exact OCEL v2 event lands on the wire (Chronicle raw-ndjson round-trip)
      with the pinned shape (`event_id`/`event_type`/`event_time`/
      `attributes`/`relationships`);
    * dispatch stop AND dispatch exception conversions, including a typed
      redacted error kind (never a stacktrace) and `acted_on` relationships;
    * overflow drops the OLDEST events with `drop_count/1` plus
      `[:ash_a2a, :ocel_broadcaster, :dropped]` telemetry, never
      backpressure — after the overflow only the NEWEST events flush;
    * a flush against a dead endpoint is a typed failure
      (`[:ash_a2a, :ocel_broadcaster, :flush_failed]`), the events are
      re-buffered, and the broadcaster never crashes;
    * unconfigured = started-but-idle: no buffer, no drops, no side effects.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Telemetry.OcelBroadcaster

  @store AshA2A.Enterprise.OcelBroadcasterCourtTest.Store
  @witness AshA2A.Enterprise.OcelBroadcasterCourtTest.Witness
  @resource AshA2A.Test.Fixture.FreedomGym.Facilitator

  # -- real receiver (siem_test.exs technique) ---------------------------------

  defmodule SIEMReceiver do
    @moduledoc """
    Real Plug.Router standing in for a Chronicle ingestion endpoint: captures
    every raw request body into a real Agent store and answers the platform's
    real success status/body. The raw ndjson lines round-trip equal to the
    input OCEL v2 maps, so the court asserts on exactly what left the
    broadcaster.
    """

    use Plug.Router

    @store AshA2A.Enterprise.OcelBroadcasterCourtTest.Store

    plug(:match)
    plug(:dispatch)

    post "/v2/logs" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      :ok = Agent.update(@store, fn st -> %{st | requests: st.requests ++ [body]} end)

      conn |> Plug.Conn.send_resp(200, "{}")
    end

    match(_) do
      conn |> Plug.Conn.send_resp(404, "route_not_admitted")
    end
  end

  # -- receiver harness --------------------------------------------------------

  defp start_receiver! do
    {:ok, _} = Agent.start_link(fn -> %{requests: []} end, name: @store)
    http = AshA2A.Test.EphemeralHttp.start!(SIEMReceiver)

    on_exit(fn ->
      Process.exit(http.pid, :normal)
      stop_named_agent(@store)
    end)

    http.base_url
  end

  defp stop_named_agent(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      agent ->
        ref = Process.monitor(agent)

        try do
          Agent.stop(agent)
        catch
          :exit, _already_gone -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^agent, _reason} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  # -- telemetry witness ---------------------------------------------------------

  defp attach_witness! do
    {:ok, _} = Agent.start_link(fn -> %{dropped: 0, flush_failed: 0} end, name: @witness)

    :telemetry.attach(
      {__MODULE__, :witness_dropped},
      [:ash_a2a, :ocel_broadcaster, :dropped],
      fn _event, %{count: count}, _meta, _config ->
        Agent.update(@witness, fn st -> %{st | dropped: st.dropped + count} end)
      end,
      nil
    )

    :telemetry.attach(
      {__MODULE__, :witness_flush_failed},
      [:ash_a2a, :ocel_broadcaster, :flush_failed],
      fn _event, %{count: count}, _meta, _config ->
        Agent.update(@witness, fn st -> %{st | flush_failed: st.flush_failed + count} end)
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach({__MODULE__, :witness_dropped})
      :telemetry.detach({__MODULE__, :witness_flush_failed})
      stop_named_agent(@witness)
    end)

    :ok
  end

  # -- helpers -----------------------------------------------------------------

  defp unique_name do
    :"ocel_broadcaster_court_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp sink(endpoint) do
    [
      platform: :chronicle,
      endpoint: endpoint,
      api_key: "ocel-broadcaster-court-key",
      max_retries: 1,
      backoff_base_ms: 1,
      max_backoff_ms: 5
    ]
  end

  defp emit_dispatch_stop(object_id \\ nil) do
    metadata =
      %{resource_or_domain: @resource, skill_name: :run_phase, reply_type: :reply}
      |> then(&if(object_id, do: Map.put(&1, :object_id, object_id), else: &1))

    :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1_234}, metadata)
  end

  defp emit_dispatch_exception(object_id) do
    :telemetry.execute(
      [:ash_a2a, :dispatch, :exception],
      %{duration: 5_678},
      %{
        resource_or_domain: @resource,
        skill_name: :run_phase,
        stage: :exception,
        kind: :exception,
        reason: %RuntimeError{message: "boom"},
        object_id: object_id
      }
    )
  end

  defp wait_until(fun, tries \\ 200) do
    if fun.() do
      :ok
    else
      if tries <= 0, do: flunk("condition not reached")
      Process.sleep(25)
      wait_until(fun, tries - 1)
    end
  end

  defp ndjson_lines(body) do
    body |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.map(&Jason.decode!/1)
  end

  defp requests, do: Agent.get(@store, & &1.requests)

  # -- courts ---------------------------------------------------------------------

  describe "real telemetry to SIEM wire" do
    test "dispatch stop + exception buffer as OCEL v2 and flush to a real Bandit SIEM receiver" do
      endpoint = start_receiver!()
      attach_witness!()

      name = unique_name()

      start_supervised!(
        {OcelBroadcaster, name: name, endpoints: [sink(endpoint)], flush_interval_ms: 60_000}
      )

      emit_dispatch_stop()
      emit_dispatch_exception("task-2")

      wait_until(fn -> OcelBroadcaster.buffer_count(name) >= 2 end)
      assert :ok = OcelBroadcaster.flush(name)
      wait_until(fn -> length(requests()) >= 1 end)

      assert [body] = requests()
      lines = ndjson_lines(body)
      assert length(lines) == 2
      assert [stop, exception] = lines

      # Pinned OCEL v2 shape on the wire.
      for line <- lines do
        assert is_binary(line["event_id"]) and line["event_id"] != ""
        assert is_binary(line["event_time"])
        assert is_map(line["attributes"])
      end

      assert stop["event_type"] == "ash_a2a.dispatch.facilitator.run_phase"
      assert stop["attributes"]["skill_name"] == "run_phase"
      assert stop["attributes"]["reply_type"] == "reply"
      assert stop["attributes"]["duration_native"] == "1234"
      assert stop["relationships"] == []

      assert exception["event_type"] == "ash_a2a.dispatch.facilitator.run_phase.exception"
      assert exception["attributes"]["kind"] == "exception"
      assert exception["attributes"]["error_code"] == "exception"
      assert exception["relationships"] == [%{"qualifier" => "acted_on", "object_id" => "task-2"}]

      # Clean delivery: nothing dropped, nothing failed.
      assert OcelBroadcaster.drop_count(name) == 0
      assert Agent.get(@witness, & &1.dropped) == 0
      assert Agent.get(@witness, & &1.flush_failed) == 0
    end
  end

  describe "overflow and failure" do
    test "overflow drops the OLDEST events with drop telemetry; only the newest flush" do
      endpoint = start_receiver!()
      attach_witness!()

      name = unique_name()

      start_supervised!(
        {OcelBroadcaster,
         name: name,
         endpoints: [sink(endpoint)],
         flush_interval_ms: 60_000,
         max_buffer: 2}
      )

      for i <- 1..5, do: emit_dispatch_stop("task-#{i}")

      wait_until(fn -> OcelBroadcaster.drop_count(name) == 3 end)
      assert OcelBroadcaster.buffer_count(name) == 2
      assert Agent.get(@witness, & &1.dropped) == 3

      assert :ok = OcelBroadcaster.flush(name)
      wait_until(fn -> length(requests()) >= 1 end)

      assert [body] = requests()

      object_ids =
        ndjson_lines(body) |> Enum.flat_map(& &1["relationships"]) |> Enum.map(& &1["object_id"])

      # Drop-oldest: only the two NEWEST events (task-4, task-5) flush.
      assert Enum.sort(object_ids) == ["task-4", "task-5"]
    end

    test "flush to a dead endpoint is a typed failure; events are re-buffered, no crash" do
      attach_witness!()

      name = unique_name()

      start_supervised!(
        {OcelBroadcaster,
         name: name,
         endpoints: [
           [
             platform: :chronicle,
             endpoint: "http://127.0.0.1:1",
             api_key: "k",
             max_retries: 0,
             backoff_base_ms: 1,
             max_backoff_ms: 2
           ]
         ],
         flush_interval_ms: false}
      )

      emit_dispatch_stop("task-1")
      emit_dispatch_stop("task-2")

      wait_until(fn -> OcelBroadcaster.buffer_count(name) >= 2 end)
      assert :ok = OcelBroadcaster.flush(name)

      # The typed delivery failure is witnessed on the broadcaster's own
      # telemetry surface; the events are back in the buffer (drop-oldest
      # bounded; max_buffer default 10_000, so zero drops).
      assert Agent.get(@witness, & &1.flush_failed) == 1
      assert OcelBroadcaster.buffer_count(name) == 2
      assert OcelBroadcaster.drop_count(name) == 0

      # The broadcaster survived (no crash, no backpressure).
      assert is_pid(Process.whereis(name))
    end

    test "unconfigured broadcaster is started-but-idle: no buffer, no drops, no side effects" do
      name = unique_name()

      start_supervised!({OcelBroadcaster, name: name, flush_interval_ms: 60_000})

      assert OcelBroadcaster.configured?(name) == false

      emit_dispatch_stop("task-1")
      emit_dispatch_exception("task-2")
      assert :ok = OcelBroadcaster.flush(name)

      assert OcelBroadcaster.buffer_count(name) == 0
      assert OcelBroadcaster.drop_count(name) == 0
      assert is_pid(Process.whereis(name))
    end
  end
end
