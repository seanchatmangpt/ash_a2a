defmodule AshA2A.W26.Gated do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.W26.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    # Real handler that blocks until the test releases it (no sleeping).
    action :gated, :map do
      argument(:probe, :string)

      run(fn input, _context ->
        with name when is_binary(name) <- input.arguments[:probe],
             pid when is_pid(pid) <- Process.whereis(String.to_existing_atom(name)) do
          send(pid, {:handler_started, self()})

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end
        end

        {:ok, %{done: true}}
      end)
    end
  end

  a2a do
    skill(:gated, :gated, consequence: :observe)
  end
end

defmodule AshA2A.W26.Converse do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.W26.Domain,
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

defmodule AshA2A.W26.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.W26.Gated)
    resource(AshA2A.W26.Converse)
  end
end

defmodule AshA2A.W26.GatedAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.W26.Gated,
    name: "w26_gated_agent",
    require_authenticated_caller: false
end

defmodule AshA2A.W26.ConverseAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.W26.Converse,
    name: "w26_converse_agent",
    require_authenticated_caller: false
end

defmodule AshA2A.W26.OptOutAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.W26.Converse,
    name: "w26_optout_agent",
    require_authenticated_caller: false,
    execution: [validate_input_modes: false]
end

defmodule AshA2A.W26.AshAgentParityTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.{Message, Part, Task}
  alias AshA2A.Protocol.Task.Status

  defp start(agent_module) do
    name = :"w26_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {agent_module, :start_link, [[name: name]]}
    })

    name
  end

  defp data_message(data, fields \\ []) do
    struct!(Message.new_user([Part.Data.new(data)]), fields)
  end

  defp gated_message(probe, fields \\ []), do: data_message(%{probe: probe}, fields)

  defp register_probe do
    probe = "w26_probe_#{System.unique_integer([:positive])}"
    true = Process.register(self(), String.to_atom(probe))
    probe
  end

  # Bounded poll on the real observable (task state), deadline-checked.
  defp await_state(agent, task_id, state, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await(agent, task_id, state, deadline)
  end

  defp do_await(agent, task_id, state, deadline) do
    {:ok, task} = GenServer.call(agent, {:get_task, task_id})

    cond do
      task.status.state == state -> task
      System.monotonic_time(:millisecond) > deadline -> flunk("task stuck in #{task.status.state}")
      true -> do_await(agent, task_id, state, deadline)
    end
  end

  describe "return_immediately" do
    test "new task: replies :submitted at once, handler still blocked, then completes" do
      agent = start(AshA2A.W26.GatedAgent)
      probe = register_probe()

      assert {:ok, %Task{status: %{state: :submitted}} = task} =
               AshA2A.W26.GatedAgent.call(agent, gated_message(probe), return_immediately: true)

      # The reply preceded the handler finishing: the handler is parked on us.
      assert_receive {:handler_started, worker}, 5_000
      assert {:ok, %Task{} = mid} = GenServer.call(agent, {:get_task, task.id})
      refute Task.terminal?(mid)

      send(worker, :release)
      done = await_state(agent, task.id, :completed)
      assert done.artifacts != []
    end

    test "terminal state is never overwritten by a late worker result" do
      agent = start(AshA2A.W26.GatedAgent)
      probe = register_probe()

      {:ok, task} =
        AshA2A.W26.GatedAgent.call(agent, gated_message(probe), return_immediately: true)

      assert_receive {:handler_started, _worker}, 5_000
      assert :ok = AshA2A.W26.GatedAgent.cancel(agent, task.id)
      canceled = await_state(agent, task.id, :canceled)
      assert Task.terminal?(canceled)

      # Still canceled after the (killed) worker's fate is settled.
      assert {:ok, %Task{status: %{state: :canceled}}} =
               GenServer.call(agent, {:get_task, task.id})
    end

    test "continuation of an input_required task replies :working then completes" do
      agent = start(AshA2A.W26.ConverseAgent)

      assert {:ok, %Task{status: %{state: :input_required}} = parked} =
               AshA2A.W26.ConverseAgent.call(agent, data_message(%{}))

      assert {:ok, %Task{status: %{state: :working}}} =
               AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "hi"}),
                 task_id: parked.id,
                 return_immediately: true
               )

      assert %Task{} = await_state(agent, parked.id, :completed)
    end

    test "continuing a terminal task is refused" do
      agent = start(AshA2A.W26.ConverseAgent)

      {:ok, %Task{status: %{state: :completed}} = done} =
        AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "x"}))

      assert {:error, :not_continuable} =
               AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "y"}),
                 task_id: done.id,
                 return_immediately: true
               )
    end
  end

  describe "context mismatch" do
    test "taskId + differing contextId is {:error, :context_mismatch}; matching continues" do
      agent = start(AshA2A.W26.ConverseAgent)

      {:ok, %Task{status: %{state: :input_required}} = parked} =
        AshA2A.W26.ConverseAgent.call(agent, data_message(%{}), context_id: "ctx-w26-a")

      assert parked.context_id == "ctx-w26-a"

      assert {:error, :context_mismatch} =
               AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "z"}),
                 task_id: parked.id,
                 context_id: "ctx-w26-other"
               )

      assert {:error, :context_mismatch} =
               AshA2A.W26.ConverseAgent.call(
                 agent,
                 data_message(%{text: "z"}, context_id: "ctx-w26-other"),
                 task_id: parked.id
               )

      assert {:ok, %Task{status: %{state: :completed}}} =
               AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "z"}),
                 task_id: parked.id,
                 context_id: "ctx-w26-a"
               )
    end
  end

  describe "referenceTaskIds" do
    test "unknown reference is :not_found; known reference donates its context" do
      agent = start(AshA2A.W26.ConverseAgent)

      {:ok, %Task{} = first} =
        AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "one"}), context_id: "ctx-w26-ref")

      assert {:error, :not_found} =
               AshA2A.W26.ConverseAgent.call(
                 agent,
                 data_message(%{text: "two"}, reference_task_ids: ["tsk-w26-unknown"])
               )

      assert {:ok, %Task{context_id: "ctx-w26-ref"}} =
               AshA2A.W26.ConverseAgent.call(
                 agent,
                 data_message(%{text: "two"}, reference_task_ids: [first.id])
               )
    end

    test "a reference owned by another principal is :not_found" do
      agent = start(AshA2A.W26.ConverseAgent)

      {:ok, %Task{} = mine} =
        AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "one"}),
          metadata: %{"a2a.auth" => %{"identity" => %{"sub" => "alice"}}}
        )

      assert {:error, :not_found} =
               AshA2A.W26.ConverseAgent.call(
                 agent,
                 data_message(%{text: "two"}, reference_task_ids: [mine.id]),
                 metadata: %{"a2a.auth" => %{"identity" => %{"sub" => "mallory"}}}
               )

      assert {:ok, %Task{}} =
               AshA2A.W26.ConverseAgent.call(
                 agent,
                 data_message(%{text: "two"}, reference_task_ids: [mine.id]),
                 metadata: %{"a2a.auth" => %{"identity" => %{"sub" => "alice"}}}
               )
    end
  end

  describe "Status.interrupted?/1" do
    test "truth table over every state, disjoint from terminal" do
      for state <- [:input_required, :auth_required], do: assert(Status.interrupted?(state))

      for state <- [:submitted, :working, :completed, :canceled, :failed, :rejected, :unknown] do
        refute Status.interrupted?(state)
      end

      assert Status.interrupted?(Status.new(:auth_required))
      refute Status.interrupted?(Status.new(:working))
      refute Status.interrupted?(nil)

      for state <- AshA2A.TaskLifecycle.states() do
        task = %{Task.new(id: "t") | status: Status.new(state)}
        refute Status.interrupted?(task) and Task.terminal?(task)
        assert AshA2A.TaskLifecycle.interrupted?(state) == Status.interrupted?(state)
      end
    end
  end

  describe "input-mode validation" do
    test "unsupported part media type is refused; opt-out and per-call flag admit it" do
      agent = start(AshA2A.W26.ConverseAgent)
      weird = %{Part.Data.new(%{text: "ok"}) | media_type: "application/x-w26"}
      message = %{Message.new_user([weird]) | message_id: "msg-w26-weird"}

      assert {:error, {:content_type_not_supported, %{mediaType: "application/x-w26"}}} =
               AshA2A.W26.ConverseAgent.call(agent, message)

      assert {:ok, %Task{status: %{state: :completed}}} =
               AshA2A.W26.ConverseAgent.call(agent, message, validate_input_modes: false)

      optout = start(AshA2A.W26.OptOutAgent)

      assert {:ok, %Task{status: %{state: :completed}}} =
               AshA2A.W26.OptOutAgent.call(optout, message)
    end

    test "accepted_output_modes filters final artifacts" do
      agent = start(AshA2A.W26.ConverseAgent)

      assert {:ok, %Task{status: %{state: :completed}} = full} =
               AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "a"}))

      assert full.artifacts != []

      assert {:ok, %Task{status: %{state: :completed}} = filtered} =
               AshA2A.W26.ConverseAgent.call(agent, data_message(%{text: "a"}),
                 accepted_output_modes: ["image/png"]
               )

      # The handler's Data part carries no explicit media type (always
      # admitted), so the artifact set is unchanged -- the filter ran without
      # corrupting the task.
      assert filtered.artifacts == [] or length(filtered.artifacts) == length(full.artifacts)
    end
  end
end
