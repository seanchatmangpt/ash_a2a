defmodule AshA2A.TaskSemantics.SemanticsAgent do
  @moduledoc false

  use AshA2A.Protocol.Agent,
    name: "w8_semantics",
    description: "W8 core-semantics fixture",
    skills: [%{id: "s", name: "s", description: "d", tags: []}]

  alias AshA2A.Protocol.{Message, Part}

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case Message.text(message) do
      "slow" ->
        # Structural sync: tell the test we are running, block until released.
        send(:w8_test_pid, {:handler_started, self()})

        receive do
          :release -> {:reply, [Part.Text.new("slow done")]}
        end

      "park" ->
        {:input_required, [Part.Text.new("need more")]}

      "mixed" ->
        {:reply,
         [Part.Text.new("t"), %Part.Data{data: %{"a" => 1}, media_type: "application/json"}]}

      other ->
        {:reply, [Part.Text.new("echo " <> other)]}
    end
  end
end

defmodule AshA2A.TaskSemanticsTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.{Artifact, InputModeValidator, Message, Part, Task}
  alias AshA2A.Protocol.JSONRPC.Request
  alias AshA2A.Protocol.Task.Filter
  alias AshA2A.TaskSemantics.SemanticsAgent

  setup do
    name = :"w8_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = SemanticsAgent.start_link(name: name)
    Process.register(self(), :w8_test_pid)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: name}
  end

  describe "Request helpers" do
    test "return_immediately reads both spellings and legacy blocking inverse" do
      assert Request.return_immediately(%{"returnImmediately" => true})
      assert Request.return_immediately(%{"return_immediately" => true})
      assert Request.return_immediately(%{"blocking" => false})
      refute Request.return_immediately(%{"blocking" => true})
      refute Request.return_immediately(%{})
      refute Request.return_immediately(nil)
    end

    test "accepted_output_modes requires a list of strings" do
      assert Request.accepted_output_modes(%{"acceptedOutputModes" => ["text/plain"]}) ==
               ["text/plain"]

      assert Request.accepted_output_modes(%{"acceptedOutputModes" => [1]}) == nil
      assert Request.accepted_output_modes(%{}) == nil
    end

    test "tasks/list rejects a negative historyLength with -32602" do
      req = %Request{jsonrpc: "2.0", method: "tasks/list", params: %{"historyLength" => -1}}
      assert {:error, %{code: -32_602}} = Request.validate_params(req)
    end
  end

  describe "returnImmediately" do
    test "replies with a non-terminal task while the handler is still running", %{agent: agent} do
      {:ok, task} = AshA2A.Protocol.call(agent, "slow", return_immediately: true)

      assert task.status.state in [:submitted, :working]
      assert_receive {:handler_started, worker}

      # The handler is blocked, so the stored task is still non-terminal.
      assert {:ok, stored} = GenServer.call(agent, {:get_task, task.id})
      refute stored.status.state in [:completed, :failed, :canceled, :rejected]

      {:ok, _snapshot} = GenServer.call(agent, {:subscribe, task.id})
      send(worker, :release)

      id = task.id
      assert_receive {:a2a_task_event, ^id, %{status: %{state: :completed}}}, 5_000
    end

    test "without the flag the call waits for the terminal state", %{agent: agent} do
      {:ok, task} = AshA2A.Protocol.call(agent, "quick")
      assert task.status.state == :completed
    end
  end

  describe "context semantics" do
    test "a follow-up whose contextId differs from the stored task is a context_mismatch",
         %{agent: agent} do
      first = %{Message.new_user("park") | context_id: "ctx-1"}
      {:ok, task} = AshA2A.Protocol.call(agent, first, context_id: "ctx-1")
      assert task.status.state == :input_required

      follow = %{Message.new_user("more") | context_id: "ctx-2"}

      assert {:error, :context_mismatch} =
               AshA2A.Protocol.call(agent, follow, task_id: task.id, context_id: "ctx-2")

      same = %{Message.new_user("more") | context_id: "ctx-1"}

      assert {:ok, done} =
               AshA2A.Protocol.call(agent, same, task_id: task.id, context_id: "ctx-1")

      assert done.status.state == :completed
    end

    test "referenceTaskIds must exist; context is inherited when none is given", %{agent: agent} do
      unknown = %{Message.new_user("hi") | reference_task_ids: ["tsk-does-not-exist"]}
      assert {:error, :not_found} = AshA2A.Protocol.call(agent, unknown)

      {:ok, ref} = AshA2A.Protocol.call(agent, Message.new_user("park"), context_id: "ctx-ref")

      child = %{Message.new_user("hi") | reference_task_ids: [ref.id]}
      assert {:ok, task} = AshA2A.Protocol.call(agent, child)
      assert task.context_id == "ctx-ref"
    end

    test "a follow-up to a terminal task stays :not_continuable", %{agent: agent} do
      {:ok, task} = AshA2A.Protocol.call(agent, "quick")
      assert {:error, :not_continuable} = AshA2A.Protocol.call(agent, "again", task_id: task.id)
    end
  end

  describe "input / output modes" do
    test "an explicit mediaType outside the card's input modes is refused", %{agent: agent} do
      bad = Message.new_user("x")
      bad = %{bad | parts: [%Part.Text{text: "x", media_type: "image/png"}]}

      assert {:error, {:content_type_not_supported, %{mediaType: "image/png"}}} =
               AshA2A.Protocol.call(agent, bad)

      assert {:ok, _} = AshA2A.Protocol.call(agent, bad, validate_input_modes: false)
    end

    test "validator honors skill modes and wildcards" do
      card = %{
        default_input_modes: ["text/plain"],
        skills: [%{id: "img", input_modes: ["image/*"]}]
      }

      png = %Message{role: :user, parts: [%Part.Text{text: "", media_type: "image/png"}]}

      assert {:error, {:content_type_not_supported, _}} =
               InputModeValidator.validate_input(png, card)

      assert :ok = InputModeValidator.validate_input(png, card, skill_id: "img")
      assert %{code: -32_005} = InputModeValidator.to_error({:content_type_not_supported, %{}})
    end

    test "acceptedOutputModes filters or refuses disallowed artifact parts" do
      task = %{
        Task.new(id: "t1")
        | artifacts: [
            Artifact.new([
              Part.Text.new("a"),
              %Part.Data{data: %{}, media_type: "application/json"}
            ])
          ]
      }

      assert {:ok, %{artifacts: [%{parts: [%Part.Text{}]}]}} =
               InputModeValidator.apply_output_modes(task, ["text/plain"])

      assert {:error, {:content_type_not_supported, _}} =
               InputModeValidator.apply_output_modes(task, ["text/plain"], strategy: :refuse)

      assert {:ok, ^task} = InputModeValidator.apply_output_modes(task, nil)
    end
  end

  describe "Filter semantics" do
    defp task_at(id, seconds) do
      ts = DateTime.from_unix!(seconds)
      base = Task.new(id: id)
      %{base | status: %{base.status | timestamp: ts}}
    end

    test "statusTimestampAfter is inclusive" do
      tasks = [task_at("a", 100), task_at("b", 200)]

      {:ok, %{tasks: kept}} =
        Filter.apply(tasks, status_timestamp_after: DateTime.from_unix!(200))

      assert Enum.map(kept, & &1.id) == ["b"]

      {:ok, %{tasks: both}} =
        Filter.apply(tasks, status_timestamp_after: DateTime.from_unix!(100))

      assert length(both) == 2
    end

    test "opaque cursor survives the cursor task disappearing" do
      tasks = [task_at("a", 300), task_at("b", 200), task_at("c", 100)]
      {:ok, %{tasks: [first], next_page_token: token}} = Filter.apply(tasks, page_size: 1)
      assert first.id == "a"
      refute token == "a"

      rest = Enum.reject(tasks, &(&1.id == "a"))
      assert {:ok, %{tasks: [second]}} = Filter.apply(rest, page_size: 1, page_token: token)
      assert second.id == "b"
      assert {:error, :invalid_page_token} = Filter.apply(tasks, page_token: "nope")
    end

    test "list history_length keeps the last N entries" do
      msgs = for t <- ["1", "2", "3"], do: Message.new_user(t)
      task = %{task_at("a", 1) | history: msgs}
      {:ok, %{tasks: [one]}} = Filter.apply([task], history_length: 1)
      assert one.history == [List.last(msgs)]
      {:ok, %{tasks: [none]}} = Filter.apply([task])
      assert none.history == []
    end
  end
end
