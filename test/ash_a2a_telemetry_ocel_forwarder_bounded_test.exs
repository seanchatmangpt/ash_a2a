defmodule AshA2A.Telemetry.OcelForwarderBoundedTest do
  @moduledoc """
  Chicago-school proof closing A2A-2602 (docs/jira/v26.9.15): the OCEL
  forwarder's per-event supervised-task fan-out must be BOUNDED, and every
  event beyond the bound must be an ACCOUNTED shed -- never an unbounded
  process spawn and never a silent drop.

  Everything real: a real Bandit HTTP listener whose `/ocel/events` handler
  really sleeps (holding each forwarding task's real `Req.post` in flight
  while measuring true observed concurrency), a real `Task.Supervisor`
  started with `max_children: 2`, real `AshA2A.Dispatcher.dispatch/5` calls
  firing the real `[:ash_a2a, :dispatch, :stop]` telemetry events, and the
  forwarder's real `:counters`-backed shed accounting plus real
  `[:ash_a2a, :ocel, :shed]` telemetry.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.Facilitator

  @max_children 2
  @burst 12
  @slow_ms 400

  defmodule SlowOcelIngest do
    @moduledoc """
    Real Plug router that REALLY sleeps per request while tracking the
    maximum number of concurrently-served requests -- the cross-process
    observation of actual forwarding concurrency. Same duplicated-not-
    -shared module shape as the sibling OcelForwarder test files.
    """
    use Plug.Router

    @slow_ms 400

    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      Agent.update(SlowOcelIngest.Store, fn %{active: active, max: max} = s ->
        %{s | active: active + 1, max: max(max, active + 1)}
      end)

      Process.sleep(@slow_ms)

      Agent.update(SlowOcelIngest.Store, fn %{active: active} = s -> %{s | active: active - 1} end)
      Agent.update(SlowOcelIngest.Store, fn %{served: served} = s -> %{s | served: served + 1} end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, Jason.encode!(%{"ok" => true}))
    end

    match(_) do
      conn |> Plug.Conn.send_resp(404, "not found")
    end
  end

  setup do
    {:ok, _} =
      Agent.start_link(fn -> %{active: 0, max: 0, served: 0} end, name: SlowOcelIngest.Store)

    port = Enum.random(24_000..24_999)
    {:ok, _} = Bandit.start_link(plug: SlowOcelIngest, port: port, ip: {127, 0, 0, 1})

    supervisor_name =
      Module.concat(__MODULE__, "BoundedTaskSupervisor#{System.unique_integer([:positive])}")

    start_supervised!({Task.Supervisor, name: supervisor_name, max_children: @max_children})

    parent = self()

    :ok =
      :telemetry.attach_many(
        {__MODULE__, :shed_probe},
        [
          [:ash_a2a, :ocel, :shed]
        ],
        fn _event, _measurements, _meta, _config -> send(parent, :shed_telemetry) end,
        nil
      )

    Application.put_env(:ash_a2a, :ocel_ingest_url, "http://127.0.0.1:#{port}")
    Application.put_env(:ash_a2a, :ocel_task_supervisor, supervisor_name)
    Application.put_env(:ash_a2a, :ocel_ingest_timeout_ms, @slow_ms * 3)
    :ok = AshA2A.Telemetry.OcelForwarder.attach!()

    on_exit(fn ->
      AshA2A.Telemetry.OcelForwarder.detach()
      :telemetry.detach({__MODULE__, :shed_probe})
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
      Application.delete_env(:ash_a2a, :ocel_task_supervisor)
      Application.delete_env(:ash_a2a, :ocel_ingest_timeout_ms)
    end)

    {:ok, supervisor_name: supervisor_name}
  end

  test "a real dispatch burst against a slow real ingest never exceeds max_children and every excess event is an accounted shed",
       %{supervisor_name: supervisor_name} do
    baseline_sheds = AshA2A.Telemetry.OcelForwarder.shed_count()

    # Fire the burst: each real dispatch's `[:ash_a2a, :dispatch, :stop]`
    # span synchronously invokes the forwarder handler, which starts at
    # most @max_children supervised tasks and sheds the rest.
    for i <- 1..@burst do
      message = data_message(%{phase: :"bounded_probe_#{i}", prompt_text: "burst #{i}"})
      assert {:reply, _} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator, [], nil)
    end

    # While the admitted tasks are still really sleeping, the supervised
    # child count is already bounded at the ceiling (2) -- not 12.
    assert %{active: active, max: observed_max} = Agent.get(SlowOcelIngest.Store, & &1)
    assert active <= @max_children
    assert observed_max <= @max_children

    counts = Supervisor.count_children(Process.whereis(supervisor_name))
    assert counts.active <= @max_children
    assert counts.workers <= @max_children

    shed_delta = AshA2A.Telemetry.OcelForwarder.shed_count() - baseline_sheds
    assert shed_delta > 0

    # Every shed event was observable telemetry, not a silent drop.
    assert_receive :shed_telemetry, 1_000

    # Accounting closes over the whole burst: every dispatched event is
    # either eventually served by the real endpoint or explicitly shed.
    wait_until(fn ->
      Agent.get(SlowOcelIngest.Store, & &1).served + shed_delta == @burst
    end)

    final = Agent.get(SlowOcelIngest.Store, & &1)
    assert final.max <= @max_children
    assert final.served + shed_delta == @burst
  end

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    unless fun.() or System.monotonic_time(:millisecond) > deadline do
      Process.sleep(50)
      wait_until(fun)
    end
  end
end
