defmodule AshA2A.TransportFollow.Note do
  @moduledoc """
  Real ETS fixture resource: `:slow` sleeps `delay_ms` before answering, so a
  stream's handler is quiet for a known time.
  """

  use Ash.Resource,
    domain: AshA2A.TransportFollow.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :slow, :map do
      argument(:delay_ms, :integer, allow_nil?: false)

      run(fn input, _context ->
        # SLEEP-CLASS: SIMULATED-SLOW-HANDLER (a handler that is quiet while it works)
        Process.sleep(input.arguments.delay_ms)
        {:ok, %{done: true}}
      end)
    end
  end

  a2a do
    skill(:slow, :slow, consequence: :observe)
  end
end

defmodule AshA2A.TransportFollow.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.TransportFollow.Note)
  end
end

defmodule AshA2A.TransportFollow.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportFollow.Note,
    name: "transport_follow_agent"
end

defmodule AshA2A.Transport.FollowTest do
  @moduledoc """
  The stream of one task (`AshA2A.Transport.Follow`), against a real agent
  whose handler is quiet for longer than the stream's tick: the Task is
  available before the handler returns, silence does not end the stream, and
  a configured idle bound does. The tick is shortened by option; nothing
  sleeps for the default 15 s.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Event.StatusUpdate
  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Transport.Follow

  setup do
    name = :"transport_follow_#{System.unique_integer([:positive])}"
    {:ok, pid} = AshA2A.TransportFollow.Agent.start_link(name: name)

    on_exit(fn ->
      try do
        AshA2A.TestSupport.SafeStop.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{agent: name}
  end

  defp admit(agent, delay_ms) do
    message = Message.new_user([Part.Data.new(%{"delay_ms" => delay_ms})])
    started = System.monotonic_time(:millisecond)
    assert {:ok, %T{} = task} = AshA2A.Protocol.call(agent, message, Follow.admit_opts([]))
    {task, System.monotonic_time(:millisecond) - started}
  end

  test "the task is answered before the handler returns, and is working", %{agent: agent} do
    {task, elapsed} = admit(agent, 400)
    assert elapsed < 400
    assert task.status.state == :working
    assert {:ok, %T{status: %{state: :working}}} = GenServer.call(agent, {:get_task, task.id})
  end

  test "a handler quiet for many ticks does not end the stream", %{agent: agent} do
    {task, _elapsed} = admit(agent, 400)
    wired = Follow.wire(task)

    events =
      agent
      |> Follow.events(wired, [wired], :send, subscribed?: true, tick_ms: 20, keepalive: true)
      |> Enum.to_list()

    # One keepalive per silent tick while the handler slept.
    assert Enum.count(events, &(&1 == :keepalive)) >= 5

    assert [%T{id: id} | _] = events
    assert id == task.id

    assert %StatusUpdate{status: %{state: :completed}, final: true} = List.last(events)

    generations =
      for %{generation: generation} <- Enum.reject(events, &(&1 == :keepalive)),
          do: generation

    assert generations == Enum.sort(generations)
    assert Enum.uniq(generations) == generations
  end

  test "without keepalive the same stream yields only the task's events", %{agent: agent} do
    {task, _elapsed} = admit(agent, 200)
    wired = Follow.wire(task)

    events =
      agent
      |> Follow.events(wired, [wired], :send, subscribed?: true, tick_ms: 20)
      |> Enum.to_list()

    refute :keepalive in events
    assert %StatusUpdate{status: %{state: :completed}} = List.last(events)
  end

  test "a missed notification is recovered at the next tick", %{agent: agent} do
    {task, _elapsed} = admit(agent, 100)
    wired = Follow.wire(task)

    # Not subscribed at all: this process is shown nothing. The stream still
    # converges, because every tick reads the task again.
    stream = Follow.events(agent, wired, [wired], :send, subscribed?: true, tick_ms: 20)

    receive do
      {:a2a_task_event, _id, _task} -> :ok
    after
      1_000 -> flunk("the admission-time subscription delivered nothing")
    end

    flush_task_events()
    assert %StatusUpdate{status: %{state: :completed}} = stream |> Enum.to_list() |> List.last()
  end

  test "a configured idle bound ends a silent stream; the task keeps running", %{agent: agent} do
    {task, _elapsed} = admit(agent, 600)
    wired = Follow.wire(task)
    started = System.monotonic_time(:millisecond)

    events =
      agent
      |> Follow.events(wired, [wired], :send, subscribed?: true, tick_ms: 20, max_idle_ms: 100)
      |> Enum.to_list()

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 600
    assert events == [wired]
    assert Follow.running?(agent, task.id)
  end

  test "stream options are read from a transport context" do
    assert Follow.stream_opts(%{stream_tick_ms: 50, stream_max_idle_ms: 900}) ==
             [tick_ms: 50, max_idle_ms: 900]

    # The earlier key is read as the bound.
    assert Follow.stream_opts(%{stream_idle_ms: 2_000}) == [max_idle_ms: 2_000]
    assert Follow.stream_opts(%{stream_tick_ms: 0}) == []
    assert Follow.stream_opts([]) == []
  end

  defp flush_task_events do
    receive do
      {:a2a_task_event, _id, _task} -> flush_task_events()
    after
      150 -> :ok
    end
  end
end
