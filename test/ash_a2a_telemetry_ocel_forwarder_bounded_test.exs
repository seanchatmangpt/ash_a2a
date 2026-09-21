defmodule AshA2A.Telemetry.OcelForwarderBoundedTest do
  @moduledoc """
  Chicago-school evidence for A2A-2602: OCEL forwarding has a hard concurrent
  task ceiling, and every event that cannot enter that bounded task supervisor
  is explicitly accounted as a shed.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.FreedomGym.Facilitator

  @max_children 2
  @burst 12
  @slow_ms 400

  defmodule SlowOcelIngest do
    use Plug.Router

    @slow_ms 400

    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      Agent.update(SlowOcelIngest.Store, fn %{active: active, max: max} = state ->
        %{state | active: active + 1, max: max(max, active + 1)}
      end)

      Process.sleep(@slow_ms)

      Agent.update(SlowOcelIngest.Store, fn %{active: active} = state ->
        %{state | active: active - 1}
      end)

      Agent.update(SlowOcelIngest.Store, fn %{served: served} = state ->
        %{state | served: served + 1}
      end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, Jason.encode!(%{"ok" => true}))
    end

    match(_) do
      Plug.Conn.send_resp(conn, 404, "not found")
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
        [[:ash_a2a, :ocel, :shed]],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:shed_telemetry, metadata})
        end,
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

  test "a real dispatch burst never exceeds max_children and every excess event is accounted",
       %{supervisor_name: supervisor_name} do
    baseline_sheds = AshA2A.Telemetry.OcelForwarder.shed_count()

    for i <- 1..@burst do
      message = data_message(%{phase: :"bounded_probe_#{i}", prompt_text: "burst #{i}"})
      assert {:reply, _} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator, [], nil)
    end

    assert %{active: active, max: observed_max} = Agent.get(SlowOcelIngest.Store, & &1)
    assert active <= @max_children
    assert observed_max <= @max_children

    counts = Supervisor.count_children(Process.whereis(supervisor_name))
    assert counts.active <= @max_children
    assert counts.workers <= @max_children

    shed_delta = AshA2A.Telemetry.OcelForwarder.shed_count() - baseline_sheds
    assert shed_delta > 0
    assert_receive {:shed_telemetry, %{reason: :max_children}}, 1_000

    wait_until(fn ->
      Agent.get(SlowOcelIngest.Store, & &1).served + shed_delta == @burst
    end)

    final = Agent.get(SlowOcelIngest.Store, & &1)
    assert final.max <= @max_children
    assert final.served + shed_delta == @burst
  end

  test "a missing task supervisor is also an accounted shed rather than a synchronous crash" do
    missing =
      Module.concat(__MODULE__, "MissingTaskSupervisor#{System.unique_integer([:positive])}")

    Application.put_env(:ash_a2a, :ocel_task_supervisor, missing)
    baseline_sheds = AshA2A.Telemetry.OcelForwarder.shed_count()

    message = data_message(%{phase: :missing_supervisor, prompt_text: "missing supervisor"})
    assert {:reply, _} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator, [], nil)

    assert AshA2A.Telemetry.OcelForwarder.shed_count() - baseline_sheds == 1

    assert_receive {:shed_telemetry, %{reason: {:task_supervisor_exit, _reason}}}, 1_000
  end

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    unless fun.() or System.monotonic_time(:millisecond) > deadline do
      Process.sleep(50)
      wait_until(fun)
    end
  end
end
