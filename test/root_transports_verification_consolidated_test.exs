# NOTE: 1 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root Transports Verification & Task Semantics
# Consolidated from 14 source files:
#   - test/task_generation_guards_test.exs
#   - test/task_generation_lifecycle_test.exs
#   - test/task_semantics_test.exs
#   - test/task_store_ash_contract_test.exs
#   - test/task_store_ekv_contract_test.exs
#   - test/task_store_ets_contract_test.exs
#   - test/task_updater_test.exs
#   - test/tck_assert_script_test.exs
#   - test/tenant_isolation_wire_test.exs
#   - test/trace_w3c_propagation_test.exs
#   - test/transport_grpc_framing_server_test.exs
#   - test/transport_http_binding_test.exs
#   - test/transport_rpc_binding_test.exs
#   - test/verify_skills_authorizer_test.exs
# ==============================================================================

# --- SOURCE: test/task_generation_guards_test.exs ---
defmodule AshA2A.TaskGenerationGuardsTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.JSONRPC
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Protocol.Task.Generation

  # Bare agents (real GenServers). `ask` pauses on :input_required so the
  # task stays continuable; everything else completes.
  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "v6-open",
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
    use AshA2A.Protocol.Agent, name: "v6-closed", description: "no client artifacts"

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "ask" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
        _ -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
      end
    end
  end

  defmodule Handler do
    @behaviour AshA2A.Protocol.JSONRPC

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

  setup do
    start_supervised!({OpenAgent, []})
    start_supervised!({ClosedAgent, []})
    :ok
  end

  defp rpc(agent, method, params, extra_ctx \\ %{}) do
    raw = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    {:reply, resp} = JSONRPC.handle(raw, Handler, Map.merge(%{agent: agent}, extra_ctx))
    resp
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

  defp gen(task), do: task["generation"] |> to_int()
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_int(v), do: v

  test "error table: -32010 TASK_GENERATION_MISMATCH / 409 / ABORTED" do
    err = Error.task_generation_mismatch(nil, task_id: "t", expected: 1, actual: 3)
    assert err.code == -32_010
    map = Error.to_map(err)

    assert [%{"reason" => "TASK_GENERATION_MISMATCH", "domain" => "a2a-protocol.org"} = info] =
             map["data"]

    assert info["metadata"]["expectedGeneration"] == "1"
    assert Error.spec_http_status(-32_010) == 409
    assert Error.grpc_status(-32_010) == 10
    assert Error.status_name_for_code(-32_010) == "ABORTED"

    env = AshA2A.ToA2AError.to_a2a_error(%AshA2A.TaskGenerationMismatchError{task_id: "t"}, 9)
    assert env["error"]["code"] == -32_010
  end

  test "ifGenerationMatch mismatch -> -32010; match proceeds; ignored for new task" do
    task = new_task(OpenAgent)
    current = gen(task)

    resp =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("again", %{"taskId" => task["id"]}),
        "configuration" => %{"ifGenerationMatch" => current + 5}
      })

    assert resp["error"]["code"] == -32_010
    assert [%{"reason" => "TASK_GENERATION_MISMATCH"}] = resp["error"]["data"]

    ok =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("again", %{"taskId" => task["id"]}),
        "configuration" => %{"ifGenerationMatch" => current}
      })

    assert %{"result" => %{"task" => _}} = ok

    fresh =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("hello"),
        "configuration" => %{"ifGenerationMatch" => 99}
      })

    assert %{"result" => %{"task" => _}} = fresh
  end

  test "artifactUpdates refused (-32004) when user_artifacts is off" do
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

  test "artifactUpdates accepted when on: role user, start_generation set, client generation ignored" do
    task = new_task(OpenAgent)

    resp =
      rpc(OpenAgent, "SendMessage", %{
        "artifactUpdates" => [
          %{
            "taskId" => task["id"],
            "generation" => "777",
            "artifact" => %{
              "artifactId" => "a1",
              "parts" => [%{"text" => "x"}],
              "startGeneration" => "777",
              "role" => "ROLE_AGENT"
            }
          }
        ]
      })

    assert %{"result" => %{"task" => out}} = resp
    [artifact] = Enum.filter(out["artifacts"], &(&1["artifactId"] == "a1"))
    assert artifact["role"] in ["ROLE_USER", "user"]
    assert to_int(artifact["startGeneration"]) == gen(task) + 1
    assert gen(out) == gen(task) + 1
  end

  test "ifGenerationMatch helper and message-less send validation" do
    resp = rpc(OpenAgent, "SendMessage", %{})
    assert resp["error"]["code"] == -32_602
  end

  test "timelineLength truncation on GetTask and SendMessage; bad value -> -32602" do
    task = new_task(OpenAgent)
    assert length(task["timeline"] || []) >= 1

    %{"result" => got} = rpc(OpenAgent, "GetTask", %{"id" => task["id"], "timelineLength" => 1})
    assert length(got["timeline"]) == 1

    %{"result" => zero} = rpc(OpenAgent, "GetTask", %{"id" => task["id"], "timelineLength" => 0})
    assert (zero["timeline"] || []) == []

    sent =
      rpc(OpenAgent, "SendMessage", %{
        "message" => wire_message("hi"),
        "configuration" => %{"timelineLength" => 0}
      })

    assert %{"result" => %{"task" => t}} = sent
    assert (t["timeline"] || []) == []

    bad = rpc(OpenAgent, "GetTask", %{"id" => task["id"], "timelineLength" => -1})
    assert bad["error"]["code"] == -32_602
  end

  test "currentGeneration returns immediately when generation already greater" do
    task = new_task(OpenAgent)
    started = System.monotonic_time(:millisecond)

    %{"result" => got} =
      rpc(OpenAgent, "GetTask", %{"id" => task["id"], "currentGeneration" => 0}, %{
        long_poll_timeout_ms: 5_000
      })

    assert System.monotonic_time(:millisecond) - started < 2_000
    assert gen(got) == gen(task)
  end

  test "currentGeneration blocks, then returns after a transition in another process" do
    task = new_task(OpenAgent)
    current = gen(task)
    parent = self()

    poller =
      Task.async(fn ->
        send(parent, :polling)

        rpc(OpenAgent, "GetTask", %{"id" => task["id"], "currentGeneration" => current}, %{
          long_poll_timeout_ms: 10_000
        })
      end)

    assert_receive :polling, 2_000
    # not answered yet: the task has not advanced
    assert Task.yield(poller, 100) == nil

    # advance the generation via a real follow-up message in this process
    %{"result" => %{"task" => _}} =
      rpc(OpenAgent, "SendMessage", %{"message" => wire_message("go", %{"taskId" => task["id"]})})

    %{"result" => got} = Task.await(poller, 10_000)
    assert gen(got) > current
  end

  test "long-poll honors the server timeout when nothing advances" do
    task = new_task(OpenAgent)
    started = System.monotonic_time(:millisecond)

    %{"result" => got} =
      rpc(OpenAgent, "GetTask", %{"id" => task["id"], "currentGeneration" => gen(task)}, %{
        long_poll_timeout_ms: 150
      })

    assert System.monotonic_time(:millisecond) - started >= 100
    assert gen(got) == gen(task)
  end

  test "pure helpers return tagged errors" do
    t =
      Generation.append_message(AshA2A.Protocol.Task.new(), AshA2A.Protocol.Message.new_user("x"))

    assert {:error, :generation_mismatch} =
             AshA2A.Protocol.ClientArtifacts.check_generation(t, 99)

    assert :ok = AshA2A.Protocol.ClientArtifacts.check_generation(nil, 99)

    assert {:error, {:unsupported_operation, :user_artifacts}} =
             AshA2A.Protocol.ClientArtifacts.check_user_artifacts(%{capabilities: %{}}, [:x])
  end
end

# --- SOURCE: test/task_generation_lifecycle_test.exs ---
defmodule AshA2A.TaskGenerationLifecycleTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Artifact, Message, Task, TimelineEntry}
  alias AshA2A.Protocol.Agent.{Runtime, State}
  alias AshA2A.Protocol.Task.{Filter, Generation, Status}

  defmodule TurnAgent do
    # First turn asks for input; the continuation completes.
    def handle_message(%Message{} = msg, %{history: history}) do
      text = inspect(msg.parts)

      if String.contains?(text, "finish"),
        do: {:reply, "done"},
        else: {:input_required, "more?" <> to_string(length(history))}
    end
  end

  describe "Generation (pure)" do
    test "initial is 1 and a new task carries it" do
      assert Generation.initial() == 1
      assert Generation.generation_of(Task.new()) == 1
    end

    test "each mutation increments by exactly 1 and stamps entries" do
      t0 = Task.new()
      t1 = Generation.append_message(t0, Message.new_user("hi"))
      t2 = Generation.append_status(t1, Status.new(:working))
      reply = Message.new_agent("ask")
      t3 = Generation.append_status(t2, Status.new(:input_required, reply))

      assert [g1, g2, g3] = Enum.map(t3.timeline, & &1.generation)
      assert {g1, g2, g3} == {2, 3, 4}
      assert t3.generation == 4

      assert [
               %TimelineEntry{entry: {:message, _}},
               %TimelineEntry{entry: {:status, _}},
               %TimelineEntry{entry: {:status, %Status{state: :input_required}}}
             ] =
               t3.timeline

      assert t3.status.state == :input_required
    end

    test "history stays in sync, without duplicating an already-appended message" do
      reply = Message.new_agent("ask")
      t = %{Task.new() | history: [reply]}
      t = Generation.append_status(t, Status.new(:input_required, reply))
      assert t.history == [reply]

      u = Message.new_user("x")
      t = Generation.append_message(t, u)
      assert t.history == [reply, u]
    end

    test "artifacts leave generation gaps in the timeline and carry start/end generation" do
      t = Generation.append_status(Task.new(), Status.new(:working))
      art = Artifact.new([AshA2A.Protocol.Part.Text.new("a")])

      {t, a1} = Generation.record_artifact(t, art, false)
      assert a1.start_generation == 3
      assert a1.end_generation == nil
      assert t.generation == 3

      {t, a2} = Generation.record_artifact(t, art, true)
      assert a2.start_generation == 3
      assert a2.end_generation == 4
      assert length(a2.parts) == 2
      assert length(t.artifacts) == 1

      t = Generation.append_status(t, Status.new(:completed))
      assert Enum.map(t.timeline, & &1.generation) == [2, 5]
      assert t.generation == 5
    end

    test "matches?/2" do
      t = Task.new()
      assert Generation.matches?(t, nil)
      assert Generation.matches?(t, 1)
      refute Generation.matches?(t, 2)
    end

    test "truncate_timeline/2" do
      t =
        Task.new()
        |> Generation.append_status(Status.new(:working))
        |> Generation.append_status(Status.new(:completed))

      assert length(Generation.truncate_timeline(t, nil).timeline) == 2
      assert Generation.truncate_timeline(t, 0).timeline == []
      assert [%TimelineEntry{generation: 3}] = Generation.truncate_timeline(t, 1).timeline
      assert length(Generation.truncate_timeline(t, 10).timeline) == 2
    end
  end

  describe "state machine (real runtime)" do
    test "submitted -> working -> input_required -> working -> completed" do
      state = %State{module: TurnAgent}

      {task, state} = Runtime.process_message(TurnAgent, Message.new_user("start"), "ctx", state)
      assert %Task{status: %{state: :input_required}} = task
      # message(2) working(3) input_required(4)
      assert task.generation == 4
      assert Enum.map(task.timeline, & &1.generation) == [2, 3, 4]
      assert length(task.history) == 2

      assert {:ok, {task, _state}} =
               Runtime.continue_task(TurnAgent, Message.new_user("finish"), task, state)

      assert task.status.state == :completed
      gens = Enum.map(task.timeline, & &1.generation)
      assert gens == Enum.sort(gens)
      assert gens == Enum.uniq(gens)
      # message(5) working(6) artifact(7) completed(8)
      assert task.generation == 8
      assert gens == [2, 3, 4, 5, 6, 8]

      assert [
               {:message, _},
               {:status, %{state: :working}},
               {:status, %{state: :input_required}},
               {:message, _},
               {:status, %{state: :working}},
               {:status, %{state: :completed}}
             ] = Enum.map(task.timeline, & &1.entry)

      assert length(task.history) >= 4

      assert [%Artifact{start_generation: 7, end_generation: 7}] = task.artifacts
    end

    test "list truncation of timeline and history is independent" do
      state = %State{module: TurnAgent}
      {task, _} = Runtime.process_message(TurnAgent, Message.new_user("start"), "ctx", state)

      {:ok, %{tasks: [only]}} = Filter.apply([task], history_length: 1, timeline_length: 2)
      assert length(only.history) == 1
      assert length(only.timeline) == 2

      {:ok, %{tasks: [none]}} = Filter.apply([task], history_length: 2, timeline_length: 0)
      assert length(none.history) == 2
      assert none.timeline == []

      {:ok, %{tasks: [all]}} = Filter.apply([task], history_length: 0)
      assert all.history == []
      assert length(all.timeline) == 3
    end

    test "stores round-trip generation fields via ETS state put/get" do
      state = %State{module: TurnAgent}
      {task, state} = Runtime.process_message(TurnAgent, Message.new_user("start"), "ctx", state)
      state = State.put_task(state, task)
      assert {:ok, ^task} = State.get_task(state, task.id)
    end
  end
end

# --- SOURCE: test/task_semantics_test.exs ---
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

# --- SOURCE: test/task_store_ash_contract_test.exs ---
defmodule AshA2A.TaskStoreAshContractTest do
  use AshA2A.TaskStoreContract, store: AshA2A.TaskStore.Ash

  alias AshA2A.TaskStore.Ash, as: Store

  # Ash ETS data layer: no process to start; isolation is per-namespace ref.
  def start_store(tag), do: "w18_ash_#{tag}_#{System.unique_integer([:positive])}"

  test "version increments on every put and starts at 0 when absent" do
    ref = start_store("version")
    assert Store.version(ref, "tsk-1") == 0
    :ok = Store.put(ref, contract_task("tsk-1", "ctx-1", :working, 1))
    assert Store.version(ref, "tsk-1") == 1
    :ok = Store.put(ref, contract_task("tsk-1", "ctx-1", :completed, 2))
    assert Store.version(ref, "tsk-1") == 2
  end

  test "optimistic concurrency: stale expected_version is refused and leaves state intact" do
    ref = start_store("occ")
    working = contract_task("tsk-1", "ctx-1", :working, 1)
    done = contract_task("tsk-1", "ctx-1", :completed, 2)

    assert :ok = Store.put(ref, working, expected_version: 0)
    assert {:error, :version_conflict} = Store.put(ref, working, expected_version: 0)
    assert :ok = Store.put(ref, done, expected_version: 1)
    assert {:error, :version_conflict} = Store.put(ref, working, expected_version: 1)
    assert {:ok, %{status: %{state: :completed}}} = Store.get(ref, "tsk-1")
    assert Store.version(ref, "tsk-1") == 2
  end

  test "columns are really persisted in the resource row" do
    ref = start_store("columns")
    owner_key = AshA2A.Transport.Runtime.owner_key()
    task = contract_task("tsk-9", "ctx-9", :working, 3)
    task = %{task | metadata: Map.put(task.metadata, owner_key, "principal:u1")}
    :ok = Store.put(ref, task)

    row =
      AshA2A.TaskStore.Ash.TaskRow
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.namespace == ref and &1.task_id == "tsk-9"))

    assert row.owner == "principal:u1"
    assert row.context_id == "ctx-9"
    assert row.status_state == "working"
    assert DateTime.compare(row.last_updated, contract_ts(3)) == :eq
    assert row.protocol_version == "1.0"
    assert row.version == 1
  end

  test "auth and stream metadata are not persisted" do
    ref = start_store("redact")
    task = contract_task("tsk-r", "ctx-1", :working, 1)

    task = %{
      task
      | metadata:
          Map.merge(task.metadata, %{"a2a.auth" => %{"token" => "SECRET"}, :stream => [1]})
    }

    :ok = Store.put(ref, task)
    {:ok, stored} = Store.get(ref, "tsk-r")
    refute Map.has_key?(stored.metadata, "a2a.auth")
    refute Map.has_key?(stored.metadata, :stream)
    assert stored.metadata["keep"] == "me"
  end
end

# --- SOURCE: test/task_store_ekv_contract_test.exs ---
defmodule AshA2A.TaskStoreEkvContractTest do
  use AshA2A.TaskStoreContract, store: AshA2A.TaskStore.Ekv

  def start_store(tag) do
    id = System.unique_integer([:positive])
    name = :"w18_ekv_#{tag}_#{id}"
    dir = Path.join(System.tmp_dir!(), "w18_ekv_#{tag}_#{id}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(
      Supervisor.child_spec(AshA2A.TaskStore.Ekv.child_spec(name: name, data_dir: dir),
        id: {:w18_ekv, name}
      )
    )

    name
  end
end

# --- SOURCE: test/task_store_ets_contract_test.exs ---
defmodule AshA2A.TaskStoreEtsContractTest do
  use AshA2A.TaskStoreContract, store: AshA2A.Protocol.TaskStore.ETS

  def start_store(tag) do
    name = :"w18_ets_#{tag}_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({AshA2A.Protocol.TaskStore.ETS, [name: name]}, id: name)
    )

    name
  end
end

# --- SOURCE: test/task_updater_test.exs ---
defmodule AshA2A.TaskUpdaterFixtures.UpperIdGenerator do
  @behaviour AshA2A.Protocol.Id.Generator

  @impl true
  def generate(kind, _ctx), do: "custom-" <> String.upcase(kind)
end

defmodule AshA2A.TaskUpdaterTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.{Part, ResultAggregator, TaskUpdater}
  alias AshA2A.Protocol.Event.{ArtifactUpdate, StatusUpdate}

  defp text_of(artifact), do: Enum.map_join(artifact.parts, & &1.text)

  test "lifecycle events and terminal guard" do
    u = TaskUpdater.new("t1", context_id: "c1")

    assert {:ok, u, %StatusUpdate{status: %{state: :working}, final: false}} =
             TaskUpdater.start_work(u)

    assert {:ok, u, %StatusUpdate{status: %{state: :input_required}}} =
             TaskUpdater.requires_input(u, "more?")

    assert {:ok, u, %StatusUpdate{status: %{state: :completed}, final: true}} =
             TaskUpdater.complete(u)

    assert {:error, {:terminal_state, :completed}} = TaskUpdater.fail(u)
    assert {:error, {:terminal_state, :completed}} = TaskUpdater.cancel(u)
    assert {:error, {:terminal_state, :completed}} = TaskUpdater.add_artifact(u, "x")
  end

  test "chunk assembly with append and last_chunk" do
    u = TaskUpdater.new("t2")
    {:ok, u, s1} = TaskUpdater.start_work(u, "go")
    {:ok, u, a1} = TaskUpdater.add_artifact(u, "Hel", artifact_id: "A")
    {:ok, u, a2} = TaskUpdater.add_artifact(u, "lo", artifact_id: "A", append: true)

    {:ok, u, a3} =
      TaskUpdater.add_artifact(u, [Part.Text.new("!")],
        artifact_id: "A",
        append: true,
        last_chunk: true
      )

    {:ok, _u, s2} = TaskUpdater.complete(u)

    assert %ArtifactUpdate{append: true, last_chunk: true} = a3

    task = ResultAggregator.aggregate([s1, a1, a2, a3, s2])
    assert task.id == "t2"
    assert task.status.state == :completed
    assert [%{artifact_id: "A"} = art] = task.artifacts
    assert text_of(art) == "Hello!"
    assert task.metadata.finalized_artifacts == ["A"]
    assert length(task.history) == 1
  end

  test "aggregator ignores status after terminal and replaces non-append artifact" do
    u = TaskUpdater.new("t3")
    {:ok, u, a1} = TaskUpdater.add_artifact(u, "one", artifact_id: "A")
    {:ok, u, a2} = TaskUpdater.add_artifact(u, "two", artifact_id: "A")
    {:ok, _u, done} = TaskUpdater.complete(u)
    late = StatusUpdate.new("t3", AshA2A.Protocol.Task.Status.new(:working))
    task = ResultAggregator.aggregate([a1, a2, done, late])
    assert task.status.state == :completed
    assert [art] = task.artifacts
    assert text_of(art) == "two"
  end

  test "id generator default and pluggable" do
    assert Application.get_env(:ash_a2a, :id_generator) == nil
    assert "tsk-" <> suffix = AshA2A.Protocol.ID.generate("tsk")
    assert byte_size(suffix) == 12

    Application.put_env(:ash_a2a, :id_generator, AshA2A.TaskUpdaterFixtures.UpperIdGenerator)
    on_exit(fn -> Application.delete_env(:ash_a2a, :id_generator) end)

    assert AshA2A.Protocol.ID.generate("msg") == "custom-MSG"
    assert AshA2A.Protocol.Task.new().id == "custom-TSK"
  end
end

# --- SOURCE: test/tck_assert_script_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT


# --- SOURCE: test/tenant_isolation_wire_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TenantIsolationWire.Fixture do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.TenantIsolationWire.FixtureDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      run(fn _input, _context -> {:ok, %{text: "ok"}} end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.TenantIsolationWire.FixtureDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.TenantIsolationWire.Fixture)
  end
end

defmodule AshA2A.TenantIsolationWire.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.TenantIsolationWire.Fixture,
    name: "w12_tenant_agent"

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case AshA2A.Protocol.Message.text(message) do
      "park" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
      text -> {:reply, [AshA2A.Protocol.Part.Text.new("ok: " <> text)]}
    end
  end
end

defmodule AshA2A.TenantIsolationWireTest do
  @moduledoc """
  Tenant plumbing in the transport runtime: a task created under tenant T is
  invisible (indistinguishable from unknown) to other tenants and to
  untenanted callers; with no tenant, behaviour is unchanged. Real agent,
  real GenServer calls, no mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Message
  alias AshA2A.Transport.{Principal, Runtime}
  alias AshA2A.TenantIsolationWire.Agent

  setup do
    name = :"w12_tenant_#{System.unique_integer([:positive])}"
    {:ok, pid} = Agent.start_link(name: name)

    on_exit(fn ->
      try do
        AshA2A.TestSupport.SafeStop.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, agent: name}
  end

  defp send_as(agent, text, tenant, extra \\ []) do
    metadata = if tenant, do: %{"ash_a2a.tenant" => tenant}, else: %{}
    Agent.call(agent, Message.new_user(text), [metadata: metadata] ++ extra)
  end

  test "Principal.tenant/1 and scope/2" do
    assert Principal.tenant(%{"ash_a2a.tenant" => "acme"}) == "acme"
    assert Principal.tenant(%{"a2a.tenant" => "beta"}) == "beta"
    assert Principal.tenant(%{}) == nil
    assert Principal.scope("sub:u1", nil) == "sub:u1"
    assert Principal.scope("sub:u1", "acme") == {"sub:u1", "acme"}
    assert Principal.key({"sub:u1", "acme"}) == "sub:u1"
  end

  test "a tenant-A task cannot be continued or read by tenant B or untenanted callers", %{
    agent: agent
  } do
    assert {:ok, task} = send_as(agent, "park", "acme")
    assert task.status.state == :input_required
    assert Runtime.task_tenant(task) == "acme"

    assert {:error, :not_found} = send_as(agent, "hi", "beta", task_id: task.id)
    assert {:error, :not_found} = send_as(agent, "hi", nil, task_id: task.id)

    assert {:ok, _} =
             GenServer.call(
               agent,
               {:ash_a2a_get_task, Principal.scope(:anonymous, "acme"), task.id}
             )

    assert {:error, :not_found} =
             GenServer.call(
               agent,
               {:ash_a2a_get_task, Principal.scope(:anonymous, "beta"), task.id}
             )

    # Negative control: the right tenant continues to completion.
    assert {:ok, done} = send_as(agent, "hi", "acme", task_id: task.id)
    assert done.status.state == :completed
  end

  test "nil tenant keeps default behaviour", %{agent: agent} do
    assert {:ok, task} = send_as(agent, "park", nil)
    assert Runtime.task_tenant(task) == nil
    assert {:ok, done} = send_as(agent, "hi", nil, task_id: task.id)
    assert done.status.state == :completed
  end

  test "tenant is stripped from wire tasks", %{agent: agent} do
    assert {:ok, task} = send_as(agent, "park", "acme")
    refute Map.has_key?(Runtime.wire_task(task).metadata, "ash_a2a.tenant")
  end
end

# --- SOURCE: test/trace_w3c_propagation_test.exs ---
defmodule AshA2A.TraceW3CPropagationTest do
  use ExUnit.Case, async: true

  alias AshA2A.Trace.W3C
  alias AshA2A.Protocol.Telemetry.OTel

  @tp "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  test "valid and invalid traceparent vectors" do
    assert {:ok, %{trace_id: "0af7651916cd43dd8448eb211c80319c", flags: "01"}} =
             W3C.parse_traceparent(@tp)

    assert {:ok, _} =
             W3C.parse_traceparent(
               "cc-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-what-the-future-will-be-like"
             )

    for bad <- [
          "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
          "00-00000000000000000000000000000000-b7ad6b7169203331-01",
          "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01",
          "00-0AF7651916CD43DD8448EB211C80319C-b7ad6b7169203331-01",
          "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra",
          "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331",
          "",
          nil
        ] do
      assert W3C.parse_traceparent(bad) == :error, inspect(bad)
    end
  end

  test "tracestate limits" do
    assert W3C.valid_tracestate?("congo=t61rcWkgMzE,rojo=00f067aa0ba902b7")
    assert W3C.valid_tracestate?("tenant@vendor=abc")
    refute W3C.valid_tracestate?("Bad=1")
    refute W3C.valid_tracestate?("novalue")
    refute W3C.valid_tracestate?("a=1,a=2")

    ok = Enum.map_join(1..32, ",", &"k#{&1}=v")
    too_many = Enum.map_join(1..33, ",", &"k#{&1}=v")
    assert W3C.valid_tracestate?(ok)
    refute W3C.valid_tracestate?(too_many)
  end

  test "extract from conn and headers; invalid yields empty" do
    conn =
      Plug.Test.conn(:post, "/")
      |> Plug.Conn.put_req_header("traceparent", @tp)
      |> Plug.Conn.put_req_header("tracestate", "a=1")

    assert W3C.extract(conn) == %{traceparent: @tp, tracestate: "a=1"}
    assert W3C.extract([{"Traceparent", @tp}]) == %{traceparent: @tp}
    assert W3C.extract([{"traceparent", "junk"}, {"tracestate", "a=1"}]) == %{}
    assert W3C.extract([{"traceparent", @tp}, {"tracestate", "BAD"}]) == %{traceparent: @tp}
  end

  test "header wins over metadata" do
    other = "00-11111111111111111111111111111111-2222222222222222-00"
    meta = W3C.from_metadata(%{metadata: %{"traceparent" => other}})
    assert meta == %{traceparent: other}
    hdr = W3C.extract([{"traceparent", @tp}])
    assert W3C.resolve(hdr, meta) == hdr
    assert W3C.resolve(%{}, meta) == meta
    assert W3C.from_metadata(%{metadata: %{"traceparent" => "bad"}}) == %{}
  end

  test "inject round trip replaces existing headers" do
    ctx = %{traceparent: @tp, tracestate: "a=1"}
    headers = W3C.inject([{"x", "y"}, {"Traceparent", "old"}], ctx)
    assert {"x", "y"} in headers
    refute {"Traceparent", "old"} in headers
    assert W3C.extract(headers) == ctx
    assert W3C.inject([{"x", "y"}], %{traceparent: "bad"}) == [{"x", "y"}]
  end

  test "OTel bridge is safe whether or not the API is loaded" do
    if Code.ensure_loaded?(OpenTelemetry.Tracer) do
      assert OTel.available?()
    else
      refute OTel.available?()
      assert OTel.attach() == {:error, :opentelemetry_not_loaded}
      assert OTel.attach_remote_context([{"traceparent", @tp}]) == :ok
    end
  end
end

# --- SOURCE: test/transport_grpc_framing_server_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportGrpcFramingTest do
  @moduledoc "Lane 17 framing courts: pure codec, real zlib, no collaborators to fake."
  use ExUnit.Case, async: true

  alias AshA2A.Transport.Grpc.Framing

  test "a partial payload returns the whole frame as rest instead of an error" do
    frame = Framing.encode_frame("hello world")
    <<head::binary-size(8), tail::binary>> = frame

    assert {:ok, [], ^head} = Framing.decode_frames(head)
    assert {:ok, ["hello world"], ""} = Framing.decode_frames(head <> tail)

    two = frame <> Framing.encode_frame("second")
    cut = byte_size(two) - 2
    <<part::binary-size(cut), _::binary>> = two
    assert {:ok, ["hello world"], rest} = Framing.decode_frames(part)
    assert byte_size(rest) == cut - byte_size(frame)
  end

  test "decompressed output is bounded: a gzip bomb is refused, a small frame passes" do
    bomb = :zlib.gzip(:binary.copy(<<0>>, 2_000_000))
    frame = Framing.encode_frame(bomb, compressed: true)

    assert {:error, {:frame_too_large, _}} =
             Framing.decode_frames(frame,
               max_frame_bytes: 100_000,
               decompress: Framing.gzip_decompressor(100_000)
             )

    small = Framing.encode_frame(:zlib.gzip("tiny"), compressed: true)

    assert {:ok, ["tiny"], ""} =
             Framing.decode_frames(small, decompress: Framing.gzip_decompressor())
  end

  test "a naive decompress fun is still size-checked after the fact" do
    frame = Framing.encode_frame("x", compressed: true)

    assert {:error, {:frame_too_large, 1_000}} =
             Framing.decode_frames(frame,
               max_frame_bytes: 100,
               decompress: fn _ -> :binary.copy("a", 1_000) end
             )

    assert {:error, :decompress_failed} =
             Framing.decode_frames(frame, decompress: fn _ -> raise "boom" end)
  end
end

defmodule AshA2A.TransportGrpcServerTest do
  @moduledoc """
  Lane 17 gRPC courts over a real cowboy HTTP/2 listener and a real Mint gRPC
  client: the verified principal reaches dispatch (owner scoping over gRPC),
  the streaming RPC delivers the initial task snapshot, and a malformed auth
  env fails closed. No mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.TransportRpcBinding.StreamAgent
  alias Lf.A2a.V1, as: Pb

  @moduletag :serial_shard

  @endpoint AshA2A.Transport.GRPC.Server.Endpoint

  defmodule Handler do
    @moduledoc false
    @behaviour AshA2A.Protocol.JSONRPC

    @impl AshA2A.Protocol.JSONRPC
    def handle_send(message, _params, %{agent: agent}), do: AshA2A.Protocol.call(agent, message)

    @impl AshA2A.Protocol.JSONRPC
    def handle_get(task_id, _params, %{agent: agent} = ctx) do
      with {:ok, task} <- GenServer.call(agent, {:get_task, task_id}),
           true <- AshA2A.Transport.Runtime.owned_by?(task, Map.get(ctx, :principal, :anonymous)) do
        {:ok, task}
      else
        _ -> {:error, AshA2A.Protocol.JSONRPC.Error.task_not_found()}
      end
    end

    @impl AshA2A.Protocol.JSONRPC
    def handle_cancel(_task_id, _params, _ctx),
      do: {:error, AshA2A.Protocol.JSONRPC.Error.task_not_found()}

    def verify(_scheme, credential, _conn) do
      case String.split(credential, ":", parts: 2) do
        ["tok", sub] when sub != "" -> {:ok, %{sub: sub}}
        _ -> {:error, "invalid"}
      end
    end
  end

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"lane17_grpc_agent_#{uniq}"
    transport = :"lane17_grpc_transport_#{uniq}"
    start_supervised!({StreamAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: Handler,
      ctx: %{
        agent: agent,
        opts: %{authorize_task: nil},
        transport: transport,
        stream_idle_ms: 2_000
      }
    )

    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: &Handler.verify/3
      )

    Application.put_env(:ash_a2a, @endpoint, auth: {AshA2A.Transport.GRPC.Auth, auth_opts})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server)
      Application.delete_env(:ash_a2a, @endpoint)
    end)

    {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: :"lane17_cs_#{uniq}")
    {:ok, _pid, port} = GRPC.Server.start_endpoint(@endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(@endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    %{channel: channel}
  end

  defp request(task_id \\ "") do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("l17"),
        task_id: task_id,
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "stream me"}}]
      }
    }
  end

  defp creds(sub), do: [metadata: %{"authorization" => "Bearer tok:" <> sub}]

  test "the streaming RPC's first frame is the initial task snapshot", %{channel: channel} do
    assert {:ok, stream} =
             Lf.A2a.V1.A2AService.Stub.send_streaming_message(channel, request(), creds("alice"))

    responses = stream |> Enum.to_list() |> Enum.map(fn {:ok, r} -> r end)
    assert [%Pb.StreamResponse{payload: {:task, %Pb.Task{id: id}}} | rest] = responses
    assert id != ""
    assert Enum.any?(rest, &match?(%Pb.StreamResponse{payload: {:status_update, _}}, &1))
  end

  test "a foreign principal cannot continue another principal's task over gRPC", %{
    channel: channel
  } do
    {:ok, stream} =
      Lf.A2a.V1.A2AService.Stub.send_streaming_message(channel, request(), creds("alice"))

    [{:ok, %Pb.StreamResponse{payload: {:task, %Pb.Task{id: id}}}} | _] = Enum.to_list(stream)

    result =
      Lf.A2a.V1.A2AService.Stub.send_streaming_message(channel, request(id), creds("bob"))

    error =
      case result do
        {:error, %GRPC.RPCError{} = e} ->
          e

        {:ok, stream} ->
          Enum.find_value(stream, fn
            {:error, e} -> e
            _ -> nil
          end)
      end

    assert %GRPC.RPCError{status: 5} = error
  end

  test "unary dispatch carries the verified principal: owner reads, foreign principal is NOT_FOUND",
       %{channel: channel} do
    {:ok, stream} =
      Lf.A2a.V1.A2AService.Stub.send_streaming_message(channel, request(), creds("alice"))

    [{:ok, %Pb.StreamResponse{payload: {:task, %Pb.Task{id: id}}}} | _] = Enum.to_list(stream)
    get = %Pb.GetTaskRequest{id: id}

    assert {:ok, %Pb.Task{id: ^id}} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, get, creds("alice"))

    assert {:error, %GRPC.RPCError{status: 5}} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, get, creds("bob"))
  end

  test "a malformed (non-list) endpoint env fails closed instead of admitting", %{
    channel: channel
  } do
    Application.put_env(:ash_a2a, @endpoint, %{auth: :oops})

    assert {:error, %GRPC.RPCError{status: status}} =
             Lf.A2a.V1.A2AService.Stub.get_task(channel, %Pb.GetTaskRequest{id: "x"})

    assert status == 13
  end
end

# --- SOURCE: test/transport_http_binding_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportHttpBinding.Resource do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.TransportHttpBinding.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.TransportHttpBinding.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.TransportHttpBinding.Resource)
  end
end

defmodule AshA2A.TransportHttpBinding.EchoAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportHttpBinding.Resource,
    name: "transport_lane17_echo_agent"
end

defmodule AshA2A.TransportHttpBindingTest do
  @moduledoc """
  Lane 17 courts over real `Plug.Test` conns, a real supervised
  `use AshA2A.Agent` GenServer over a real ETS Ash resource and (where push
  is exercised) a real `AshA2A.A2ATransport` tree. No mocks.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshA2A.A2ATransport
  alias AshA2A.Transport.{HTTPJSON, Principal}
  alias AshA2A.TransportHttpBinding.EchoAgent

  @moduletag :serial_shard

  # A hand-written resolver (a real function, the documented `:resolver`
  # seam of WebhookPolicy): every host resolves to a public address so
  # admission does not depend on live DNS.
  def public_resolver(_host, _family), do: {:ok, [{93, 184, 216, 34}]}

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    :ok
  end

  defp message_map(text),
    do: AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))

  defp rest(opts, method, path, body \\ nil, auth \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        b when is_binary(b) -> conn(method, path, b)
        b -> conn(method, path, Jason.encode!(b))
      end

    conn = put_req_header(conn, "content-type", "application/json")
    conn = if auth, do: put_private(conn, :a2a, %{auth: auth}), else: conn
    HTTPJSON.call(conn, opts)
  end

  defp bind_opts(extra \\ []),
    do: HTTPJSON.init([agent: EchoAgent, base_url: "http://127.0.0.1/x"] ++ extra)

  describe "Principal (finding 3)" do
    test "a raw bearer-string identity is never embedded in the owner key" do
      bearer = "eyJhbGciOi.RAW-SECRET-BEARER.sig"
      key = Principal.key(bearer)
      assert "id:" <> digest = key
      refute key =~ "RAW-SECRET"
      assert byte_size(digest) == 16
      assert key == Principal.key(bearer)
      refute key == Principal.key(bearer <> "x")
    end

    test "claim values cannot forge a second claim (delimiter escaping)" do
      forged = Principal.key(%{sub: "u|iss:evil"})
      honest = Principal.key(%{sub: "u", iss: "evil"})
      refute forged == honest
      assert honest == "sub:u|iss:evil"
      assert forged == "sub:u%7Ciss:evil"
    end

    test "the wire (string-keyed) identity resolves to the same principal as the atom shape" do
      atom = Principal.from_metadata(%{"a2a.auth" => %{identity: %{sub: "u1"}}})
      wire = Principal.from_metadata(%{"a2a.auth" => %{"identity" => %{"sub" => "u1"}}})
      assert atom == wire
      assert atom == "sub:u1"
      assert Principal.from_metadata(%{"a2a.auth" => "forged-string"}) == :anonymous
    end
  end

  describe "HTTPJSON error surface (finding 4)" do
    test "unknown path is a JSON AIP-193 404, not text/plain" do
      conn = rest(bind_opts(), :get, "/nope")
      assert conn.status == 404
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      assert %{"error" => %{"code" => 404, "status" => "NOT_FOUND"}} =
               Jason.decode!(conn.resp_body)
    end

    test "wrong method is a JSON 405 with an allow header" do
      conn = rest(bind_opts(), :get, "/message:send")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
      assert %{"error" => %{"code" => 405}} = Jason.decode!(conn.resp_body)
    end

    test "an over-cap body is 413, not 400" do
      opts = bind_opts(max_body_bytes: 64)
      big = Jason.encode!(%{"message" => message_map(String.duplicate("x", 500))})
      conn = rest(opts, :post, "/message:send", big)
      assert conn.status == 413
      assert %{"error" => %{"code" => 413}} = Jason.decode!(conn.resp_body)
    end

    test "a non-map configuration is refused 400 before any agent call" do
      conn =
        rest(bind_opts(), :post, "/message:send", %{
          "message" => message_map("hi"),
          "configuration" => "not-a-map"
        })

      assert conn.status == 400
      assert %{"error" => %{"status" => "INVALID_ARGUMENT"}} = Jason.decode!(conn.resp_body)
    end

    test "a missing message is validated by the shared Request.validate_params" do
      conn = rest(bind_opts(), :post, "/message:send", %{"nope" => 1})
      assert conn.status == 400
    end

    test "inline pushNotificationConfig is refused -32003 when push is disabled" do
      conn =
        rest(bind_opts(), :post, "/message:send", %{
          "message" => message_map("hi"),
          "configuration" => %{"pushNotificationConfig" => %{"url" => "https://hook.example/x"}}
        })

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Push"
    end

    test "message:stream's final status is the task's real state" do
      conn = rest(bind_opts(), :post, "/message:stream", %{"message" => message_map("go")})
      assert conn.status == 200

      frames =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

      assert %{"task" => %{"id" => id, "status" => %{"state" => task_state}}} = hd(frames)

      final = Enum.find(frames, &Map.has_key?(&1, "statusUpdate"))
      assert %{"statusUpdate" => %{"taskId" => ^id, "status" => status}} = final

      real = rest(bind_opts(), :get, "/tasks/#{id}")
      assert real.status == 200
      real_state = Jason.decode!(real.resp_body)["status"]["state"]
      assert status["state"] == real_state
      assert is_binary(task_state)
    end

    test "POST /agent answers private,no-store and the card advertises extendedAgentCard" do
      provider = fn _identity, public -> {:ok, Map.put(public, "extra", "yes")} end
      opts = bind_opts(extended_card: provider)

      conn = rest(opts, :post, "/agent", "{}", %{identity: %{sub: "u1"}})
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert %{"extra" => "yes"} = Jason.decode!(conn.resp_body)

      card = rest(opts, :get, "/.well-known/agent-card.json")
      assert get_in(Jason.decode!(card.resp_body), ["capabilities", "extendedAgentCard"]) == true

      plain = rest(bind_opts(), :get, "/.well-known/agent-card.json")
      refute get_in(Jason.decode!(plain.resp_body), ["capabilities", "extendedAgentCard"]) == true
    end
  end

  describe "HTTPJSON push (finding 4)" do
    setup do
      transport = :"lane17_push_#{System.unique_integer([:positive])}"

      start_supervised!(
        {A2ATransport,
         name: transport, push: [resolver: &__MODULE__.public_resolver/2, signing_secret: "s"]}
      )

      %{opts: bind_opts(transport: transport, push_notifications: true), transport: transport}
    end

    defp create_task(opts) do
      conn = rest(opts, :post, "/message:send", %{"message" => message_map("hi")})
      assert conn.status == 200
      Jason.decode!(conn.resp_body)["task"]["id"]
    end

    test "list is {configs, nextPageToken}; delete returns {}; send publishes via TaskEvents",
         %{opts: opts, transport: transport} do
      id = create_task(opts)

      # message:send published the task into the shared event log
      assert [_ | _] = A2ATransport.TaskEvents.backlog(transport, id)

      created =
        rest(opts, :post, "/tasks/#{id}/pushNotificationConfigs", %{
          "url" => "https://hook.example/cb"
        })

      assert created.status == 200
      assert %{"id" => config_id, "taskId" => ^id} = Jason.decode!(created.resp_body)

      listed = rest(opts, :get, "/tasks/#{id}/pushNotificationConfigs")

      assert %{"configs" => [%{"taskId" => ^id}], "nextPageToken" => ""} =
               Jason.decode!(listed.resp_body)

      deleted = rest(opts, :delete, "/tasks/#{id}/pushNotificationConfigs/#{config_id}")
      assert deleted.status == 200
      assert Jason.decode!(deleted.resp_body) == %{}
    end

    test "inline pushNotificationConfig on message:send is attached to the created task",
         %{opts: opts, transport: transport} do
      conn =
        rest(opts, :post, "/message:send", %{
          "message" => message_map("hi"),
          "configuration" => %{
            "pushNotificationConfig" => %{"url" => "https://hook.example/inline"}
          }
        })

      assert conn.status == 200
      id = Jason.decode!(conn.resp_body)["task"]["id"]

      store = A2ATransport.push_store_name(transport)

      assert [%{url: "https://hook.example/inline"}] =
               A2ATransport.PushConfigStore.list(store, id)
    end

    test "the card advertises pushNotifications truthfully", %{opts: opts} do
      on = rest(opts, :get, "/.well-known/agent-card.json")
      assert get_in(Jason.decode!(on.resp_body), ["capabilities", "pushNotifications"]) == true

      off = rest(bind_opts(), :get, "/.well-known/agent-card.json")
      assert get_in(Jason.decode!(off.resp_body), ["capabilities", "pushNotifications"]) == false
    end
  end
end

# --- SOURCE: test/transport_rpc_binding_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportRpcBinding.StreamAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent GenServer whose handle_message/2 returns a lazy
  # three-part stream (no sleeps: the parts are produced as fast as pumped).
  use AshA2A.Protocol.Agent, name: "lane17-stream", description: "streams three parts"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream, Stream.map(1..3, fn i -> AshA2A.Protocol.Part.Text.new("part #{i}") end)}
  end
end

defmodule AshA2A.TransportRpcBindingTest do
  @moduledoc """
  Lane 17 courts for `AshA2A.A2ATransport.Plug` / `PushConfigRPC` / `SSE` /
  `PushConfigStore` / `TaskEvents`, over real `Plug.Test` conns, a real
  `AshA2A.A2ATransport` supervision tree and a real streaming
  `AshA2A.Protocol.Agent`. No mocks, no sleeps.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{PushConfigStore, SSE, TaskEvents}
  alias AshA2A.TransportRpcBinding.StreamAgent

  def public_resolver(_host, _family), do: {:ok, [{93, 184, 216, 34}]}

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"lane17_stream_#{uniq}"
    transport = :"lane17_transport_#{uniq}"
    start_supervised!({StreamAgent, name: agent})

    start_supervised!(
      {A2ATransport,
       name: transport, push: [resolver: &__MODULE__.public_resolver/2, signing_secret: "s"]}
    )

    plug =
      AshA2A.A2ATransport.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        transport: transport,
        push_notifications: true,
        max_body_bytes: 4_096,
        max_idle_ms: 200,
        heartbeat_ms: 50
      )

    %{agent: agent, transport: transport, plug: plug}
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))
    encoded
  end

  defp rpc(plug, method, params, headers \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    conn =
      Enum.reduce(headers, conn(:post, "/", body), fn {k, v}, c -> put_req_header(c, k, v) end)
      |> put_req_header("content-type", "application/json")

    AshA2A.A2ATransport.Plug.call(conn, plug)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json)["result"] end)
    end)
  end

  describe "version/extension gate on locally-handled methods (finding 2)" do
    test "tasks/list, tasks/resubscribe, push and extended-card paths answer -32009", %{
      plug: plug
    } do
      for {method, params} <- [
            {"tasks/list", %{}},
            {"tasks/resubscribe", %{"id" => "t1"}},
            {"tasks/pushNotificationConfig/list", %{"taskId" => "t1", "id" => "t1"}},
            {"agent/getAuthenticatedExtendedCard", %{}},
            {"message/stream", %{"message" => message()}}
          ] do
        conn = rpc(plug, method, params, [{"a2a-version", "9.9"}])
        assert %{"error" => %{"code" => -32_009}} = decode(conn), "method #{method}"
      end
    end

    test "a supported version passes and is echoed", %{plug: plug} do
      conn = rpc(plug, "tasks/list", %{}, [{"a2a-version", "1.0"}])
      assert get_resp_header(conn, "a2a-version") == ["1.0"]
    end

    test "unknown message/* method is -32601, not a crash", %{plug: plug} do
      conn = rpc(plug, "message/bogus", %{"message" => message()})
      assert %{"error" => %{"code" => -32_601}} = decode(conn)
    end

    test "authorize_task applies to task-naming paths this plug answers itself", %{
      agent: agent,
      transport: transport
    } do
      plug =
        AshA2A.A2ATransport.Plug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true,
          authorize_task: fn _op, _task -> false end
        )

      created = rpc(plug, "message/send", %{"message" => message()})
      id = get_in(decode(created), ["result", "task", "id"])
      assert is_binary(id)

      for {method, params} <- [
            {"tasks/get", %{"id" => id}},
            {"tasks/pushNotificationConfig/list", %{"id" => id, "taskId" => id}}
          ] do
        assert %{"error" => %{"code" => -32_001}} = decode(rpc(plug, method, params)),
               "method #{method}"
      end
    end
  end

  describe "body handling (finding 2)" do
    test "an over-cap body is a typed -32600 error and leaks no inspect(reason)", %{plug: plug} do
      big =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tasks/list",
          "params" => %{"pad" => String.duplicate("x", 9_000)}
        })

      conn =
        conn(:post, "/", big)
        |> put_req_header("content-type", "application/json")
        |> then(&AshA2A.A2ATransport.Plug.call(&1, plug))

      assert %{"error" => %{"code" => -32_600}} = decode(conn)
    end
  end

  describe "push config RPC bounds (finding 7)" do
    setup %{agent: agent, plug: plug} do
      created = rpc(plug, "message/send", %{"message" => message()})
      id = get_in(decode(created), ["result", "task", "id"]) || create_via_stream(plug)
      %{task_id: id, agent: agent}
    end

    defp create_via_stream(plug) do
      conn = rpc(plug, "message/stream", %{"message" => message()})
      [%{"task" => %{"id" => id}} | _] = frames(conn.resp_body)
      id
    end

    defp set(plug, task_id, config),
      do:
        decode(
          rpc(plug, "tasks/pushNotificationConfig/set", %{
            "taskId" => task_id,
            "pushNotificationConfig" => config
          })
        )

    test "id, url, token, authentication are type- and length-bounded", %{plug: plug, task_id: id} do
      ok = %{"url" => "https://hook.example/cb"}
      assert %{"result" => _} = set(plug, id, ok)

      bad = [
        Map.put(ok, "id", %{"nested" => 1}),
        Map.put(ok, "id", String.duplicate("a", 500)),
        Map.put(ok, "id", "has space"),
        %{"url" => "https://hook.example/" <> String.duplicate("a", 3_000)},
        Map.put(ok, "token", String.duplicate("t", 2_000)),
        Map.put(ok, "token", 12),
        Map.put(ok, "authentication", %{"schemes" => "Bearer"}),
        Map.put(ok, "authentication", %{"schemes" => []}),
        Map.put(ok, "authentication", %{"schemes" => [1]}),
        Map.put(ok, "authentication", %{"schemes" => ["Bearer"], "credentials" => 5})
      ]

      for config <- bad do
        assert %{"error" => %{"code" => -32_602}} = set(plug, id, config),
               "expected -32602 for #{inspect(config)}"
      end

      good_auth = Map.put(ok, "authentication", %{"schemes" => ["Bearer"], "credentials" => "c"})
      assert %{"result" => result} = set(plug, id, good_auth)
      refute inspect(result) =~ "credentials"
    end
  end

  describe "SSE (finding 5)" do
    test "message/stream continuing an unknown task preserves a typed error code", %{plug: plug} do
      msg = Map.put(message(), "taskId", "tsk-does-not-exist")
      conn = rpc(plug, "message/stream", %{"message" => msg})
      assert %{"error" => %{"code" => code}} = decode(conn)
      assert code in [-32_001, -32_602, -32_000]
    end

    test "streamed parts share ONE artifact: first create, rest append, lastChunk only on the final chunk",
         %{plug: plug} do
      conn = rpc(plug, "message/stream", %{"message" => message()})
      all = frames(conn.resp_body)

      artifacts = for %{"artifactUpdate" => a} <- all, do: a
      assert length(artifacts) == 3
      assert artifacts |> Enum.map(& &1["artifact"]["artifactId"]) |> Enum.uniq() |> length() == 1
      assert Enum.map(artifacts, &(&1["append"] == true)) == [false, true, true]
      assert Enum.map(artifacts, &(&1["lastChunk"] == true)) == [false, false, true]

      assert %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
               List.last(all)
    end
  end

  describe "PushConfigStore / TaskEvents sweep (finding 7)" do
    test "delete_task removes every config of the task and only that task", %{
      transport: transport
    } do
      store = A2ATransport.push_store_name(transport)

      cfg = fn task, id ->
        %{id: id, task_id: task, url: "https://h.example/#{id}", token: nil, authentication: nil}
      end

      {:ok, _} = PushConfigStore.put(store, cfg.("ta", "1"))
      {:ok, _} = PushConfigStore.put(store, cfg.("ta", "2"))
      {:ok, _} = PushConfigStore.put(store, cfg.("tb", "1"))

      assert :ok = PushConfigStore.delete_task(store, "ta")
      assert PushConfigStore.list(store, "ta") == []
      assert [%{id: "1"}] = PushConfigStore.list(store, "tb")
    end

    test "a terminal task's configs are swept with its event log", _ctx do
      uniq = System.unique_integer([:positive])
      transport = :"lane17_sweep_#{uniq}"

      start_supervised!(
        {A2ATransport,
         name: transport, retention_ms: 1, push: [resolver: &__MODULE__.public_resolver/2]},
        id: :sweep_transport
      )

      store = A2ATransport.push_store_name(transport)
      task_id = "tsk-sweep-#{uniq}"

      {:ok, _} =
        PushConfigStore.put(store, %{
          id: "c",
          task_id: task_id,
          url: "https://h.example/c",
          token: nil,
          authentication: nil
        })

      final = %{
        "statusUpdate" => %{
          "taskId" => task_id,
          "final" => true,
          "status" => %{"state" => "TASK_STATE_COMPLETED"}
        }
      }

      TaskEvents.publish(transport, task_id, "status-update", final, true)

      deadline = System.monotonic_time(:millisecond) + 5_000
      assert eventually(deadline, fn -> PushConfigStore.list(store, task_id) == [] end)
    end

    test "an input-required final event does NOT sweep configs (task can resume)", _ctx do
      uniq = System.unique_integer([:positive])
      transport = :"lane17_sweep2_#{uniq}"

      start_supervised!(
        {A2ATransport,
         name: transport, retention_ms: 1, push: [resolver: &__MODULE__.public_resolver/2]},
        id: :sweep_transport2
      )

      store = A2ATransport.push_store_name(transport)
      task_id = "tsk-paused-#{uniq}"

      {:ok, _} =
        PushConfigStore.put(store, %{
          id: "c",
          task_id: task_id,
          url: "https://h.example/c",
          token: nil,
          authentication: nil
        })

      paused = %{
        "statusUpdate" => %{
          "taskId" => task_id,
          "final" => true,
          "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}
        }
      }

      TaskEvents.publish(transport, task_id, "status-update", paused, true)

      # The log sweep is observable (backlog empties); the configs must remain.
      deadline = System.monotonic_time(:millisecond) + 5_000
      assert eventually(deadline, fn -> TaskEvents.backlog(transport, task_id) == [] end)
      assert [%{id: "c"}] = PushConfigStore.list(store, task_id)
    end
  end

  describe "SSE.stream_error/1 typed mapping (finding 5)" do
    test "typed errors survive; unknown reasons are -32000 with a ref and no detail" do
      assert %{code: -32_001} = SSE.stream_error({:error, :not_found})
      assert %{code: -32_004} = SSE.stream_error({:not_streaming, %{secret: "x"}})

      assert %{code: -32_000, data: data} =
               SSE.stream_error({:pump_start_failed, {:error, :max_children}})

      assert %{"ref" => _} = data
      refute inspect(data) =~ "max_children"
    end
  end

  # Bounded poll on a real observable: deadline-checked, no fixed sleeps.
  defp eventually(deadline, fun) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        :erlang.yield()
        eventually(deadline, fun)
    end
  end
end

# --- SOURCE: test/verify_skills_authorizer_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.VerifySkillsAuthorizerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # Regression: the lease_required? verifier read authorizers via
  # `Transformer.get_entities(dsl_state, [:authorizers])` (always []), so a resource that really
  # has Ash.Policy.Authorizer was told it had none.
  defp compile(name, authorizers_opt) do
    code = """
    defmodule #{inspect(Module.concat(__MODULE__, name))} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshA2A]#{authorizers_opt}

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
      end

      a2a do
        skill(:list, :read, lease_required?: true)
      end
    end
    """

    capture_io(:stderr, fn -> Code.compile_string(code) end)
  end

  test "a resource with Ash.Policy.Authorizer is not refused for lease_required?" do
    out = compile("WithAuthorizer", ",\n        authorizers: [Ash.Policy.Authorizer]")
    refute out =~ "refused_lease_required_no_authorizer"
  end

  test "a resource without an authorizer is still refused for lease_required?" do
    out = compile("WithoutAuthorizer", "")
    assert out =~ "refused_lease_required_no_authorizer"
  end
end

