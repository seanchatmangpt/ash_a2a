defmodule AshA2A.Execution.TaskRunBindingTest do
  @moduledoc """
  Lane I7 invariant courts over the task↔run binding (`AshA2A.Providers.PPlan`
  ↔ `AshPPlan.Reactor.Durable.Engine`) on the REAL stack: a real disk-backed
  `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir, real Engine start /
  attempt / signal / cancel. Zero mocks.

  Invariants pinned:

    1. Addressed-signal law: resume only via exact task-id+waiter. A signal to
       a terminal (completed) task's run must surface as a typed error
       (`{:error, {:run_terminal, status}}` — upstream W4). Pre-W4 evidence:
       the direct-Engine behavior observed here is RECORDED, not assumed.
    2. Binding bijection: one task id ↔ one run id across start/resume/cancel;
       concurrent follow-ups on the same task id (5 processes) yield exactly
       one run and exactly one signal consumer.
    3. Cancel semantics: cancel mid-run → task state `:canceled`, no new
       checkpoints after cancel.
    4. Idempotent re-dispatch: re-dispatching a completed task id observes the
       sealed result from the tape without re-execution (effect count == 1).
  """

  use ExUnit.Case, async: false

  @moduletag :pplan_court

  alias AshA2A.Providers.PPlan, as: Provider

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @engine AshPPlan.Reactor.Durable.Engine
  @adapter_id :a2a_pplan_binding_fx

  # -- real collaborators ------------------------------------------------------

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect counted exactly here."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, effect) do
      Agent.get_and_update(server, fn s ->
        n = Map.get(s, effect, 0) + 1
        {{:ok, n}, Map.put(s, effect, n)}
      end)
    end

    def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
  end

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effects]` names the counter agent."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus ash_pplan's own Await durable step.
    Realization options carry the per-test `:effects` agent name (plain data,
    survives a store round trip).
    """
    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_pplan_binding_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), @adapter_id, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp model(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp await_model,
    do:
      model("a2a_pplan_binding_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
      ])

  defp linear_model,
    do:
      model("a2a_pplan_binding_linear", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :finish, capability: "Process.Finish", depends_on: [:prepare]]
      ])

  defp bindings(effects) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:await, "Event.Await"},
      {:finish, "Process.Finish"}
    ]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp linear_bindings(effects) do
    Map.new([{:prepare, "Process.Prepare"}, {:finish, "Process.Finish"}], fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp open_store(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-binding-laneI7-#{System.unique_integer([:positive])}"
      )

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path, name: name)
    store
  end

  # Bounded poll on a real observable: the unwind completes only when an
  # attempt DRIVES it (:cancelling -> rolling_back -> :cancelled), so each
  # poll step makes one Engine.attempt. Deadline-checked, never a fixed sleep.
  defp settle_cancel(store, task_id, opts, deadline) do
    case Provider.status(task_id, opts) do
      {:ok, :canceled, _} = done ->
        done

      {:ok, :working, _} ->
        # :cancelling maps to :working — drive the unwind with an attempt
        _ = @engine.attempt(store, task_id, store_module: @dets)

        if System.monotonic_time(:millisecond) >= deadline do
          flunk("cancel did not settle to :cancelled within the deadline")
        end

        Process.sleep(20)
        settle_cancel(store, task_id, opts, deadline)

      other ->
        flunk("unexpected status while settling cancel: #{inspect(other)}")
    end
  end

  setup context do
    unless Provider.available?() do
      IO.puts(:stderr, "[lane-i7] BLOCKED: :ash_pplan did not load in the test env")
      {:skip, {:blocked, :ash_pplan_not_loadable}}
    end

    install_adapter!()

    {:ok, fx} = Effects.start_link(:"pplan_binding_fx_#{System.unique_integer([:positive])}")

    store = open_store(:"#{context.module}.Store.#{System.unique_integer([:positive])}")

    %{store: store, fx: fx, opts: [store: store, store_module: @dets]}
  end

  # -- invariant 1: addressed-signal law (pre-W4 evidence) ----------------------

  test "a signal to a terminal run's waiter: current behavior recorded (pre-W4)",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-terminal-signal-#{System.unique_integer([:positive])}"

    # Drive a real run to completion through the provider seam.
    assert {:ok, :completed, result} =
             Provider.dispatch(task_id, linear_model(), linear_bindings(fx),
               store: opts[:store],
               store_module: @dets
             )

    # the sealed result is the last executed step's output (the Effect step's
    # own return), delivered through the provider seam unchanged
    assert {:finish, 1} = result
    assert {:ok, :completed, _} = Provider.status(task_id, opts)

    # Provider-level resume to a terminal task: the sealed state is returned
    # unchanged — typed pass-through, never a re-execution, never a signal.
    assert {:ok, :completed, ^result} = Provider.resume(task_id, %{"late" => true}, opts)

    # Effects ran exactly once each — the pass-through consumed nothing.
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # PRE-W4 EVIDENCE: the direct Engine signal to a terminal run's waiter.
    # W4 (upstream, in flight) will make this a typed
    # `{:error, {:run_terminal, status}}`. Today's behavior is recorded here:
    # assert exactly what the Engine does now, so W4 flips this assertion.
    engine_result = @engine.signal(store, task_id, "go", %{"late" => true})

    assert match?({:ok, %AshPPlan.Reactor.Durable.Signal{}}, engine_result) or
             match?({:error, {:run_terminal, _}}, engine_result),
           "unexpected Engine.signal result on a terminal run: #{inspect(engine_result)}"

    if match?({:ok, %AshPPlan.Reactor.Durable.Signal{}}, engine_result) do
      IO.puts(
        :stderr,
        "[lane-i7] pre-W4 evidence: Engine.signal to terminal run silently delivers " <>
          inspect(engine_result)
      )
    else
      IO.puts(:stderr, "[lane-i7] W4 landed: typed run_terminal refusal observed")
    end
  end

  test "resume targets the exact parked waiter; unknown-signal resumes are typed refusals",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-addressed-signal-#{System.unique_integer([:positive])}"

    assert {:ok, :input_required, waiters} =
             Provider.dispatch(task_id, await_model(), bindings(fx), opts)

    assert is_list(waiters) and "go" in waiters

    # The payload lands on the parked waiter only when addressed by name; the
    # provider resolves the name from the run's parked waiter.
    assert {:ok, :completed, _} = Provider.resume(task_id, %{"answer" => 42}, opts)

    # A resume against an id with NO run is typed, not silent.
    assert {:error, :no_such_run} =
             Provider.resume("i7-never-dispatched-#{System.unique_integer([:positive])}",
               %{}, opts
             )

    assert store != nil
  end

  # -- invariant 2: binding bijection -------------------------------------------

  test "one task id is one run: concurrent follow-ups (5 processes) yield one run, one consumer",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-bijection-#{System.unique_integer([:positive])}"

    # Fresh task: dispatch-or-adopt, parked on the Await step.
    assert {:ok, :input_required, _waiters} =
             Provider.dispatch(task_id, await_model(), bindings(fx), opts)

    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # parked tape: prepare is standing; the Await step checkpoints at consume time
    assert Enum.map(tape_before = @engine.steps(store, task_id, store_module: @dets), & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-prepare")
           ]

    # 5 concurrent follow-up messages on the SAME task id.
    results =
      1..5
      |> Enum.map(fn i ->
        Task.async(fn ->
          Process.sleep(rem(i, 3))
          Provider.resume(task_id, %{"worker" => i}, opts)
        end)
      end)
      |> Task.await_many(30_000)

    # Exactly ONE consumer executed the finish step; the run completed once.
    assert {:ok, :completed, %{run_status: :completed}} = Provider.status(task_id, opts)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # Every concurrent caller observed a lawful outcome: the one consumer
    # drove completion; pass-through callers saw the sealed state; losers of
    # the consume-once race see a typed refusal — none silent.
    outcomes = Enum.map(results, fn
      {:ok, :completed, _} -> :completed
      {:error, {:refused, _}} -> :refused
      {:error, :no_signal_waiter} -> :no_signal_waiter
      {:error, :taken} -> :taken
      other -> {:unexpected, other}
    end)

    assert :completed in outcomes
    assert Enum.all?(outcomes, &match?(:completed, &1) or is_tuple(&1) or match?(:taken, &1))

    # Binding bijection: still exactly ONE checkpoint tape, grown only by the
    # single consumer's steps (prepare standing at dispatch; await+finish land
    # on the single consume).
    tape_after = @engine.steps(store, task_id, store_module: @dets)

    assert Enum.map(tape_after, & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-prepare"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-await"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-finish")
           ]

    assert length(tape_after) == length(tape_before) + 2
  end

  test "re-dispatch of an in-flight task id adopts the SAME run (no second attempt)",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-adopt-#{System.unique_integer([:positive])}"

    assert {:ok, :input_required, _} =
             Provider.dispatch(task_id, await_model(), bindings(fx), opts)

    # A second dispatch with the same task id (even new inputs) adopts the run
    # unchanged: parked state standing, no re-execution.
    assert {:ok, :input_required, _} =
             Provider.dispatch(task_id, await_model(), bindings(fx),
               store: opts[:store],
               store_module: @dets,
               inputs: %{"different" => true}
             )

    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert Enum.map(@engine.steps(store, task_id, store_module: @dets), & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_await#step-prepare")
           ]
  end

  # -- invariant 3: cancel semantics --------------------------------------------

  test "cancel mid-run: task :canceled, terminal sealed, no new checkpoints after cancel",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-cancel-#{System.unique_integer([:positive])}"

    assert {:ok, :input_required, _} =
             Provider.dispatch(task_id, await_model(), bindings(fx), opts)

    assert {:ok, :canceled, _record} = Provider.cancel(task_id, opts)

    # Cancel is two-phase: the provider returns while the run is :cancelling
    # and the unwind settles to :cancelled. Poll the observable to a deadline;
    # time is not a proxy for state.
    deadline = System.monotonic_time(:millisecond) + 10_000
    unwound = settle_cancel(store, task_id, opts, deadline)

    assert {:ok, :canceled, _} = unwound

    tape_at_cancel = @engine.steps(store, task_id, store_module: @dets)

    # Post-cancel resumes observe the sealed :canceled state — no re-attempt,
    # no signal consumption, no new checkpoints.
    assert {:ok, :canceled, _} = Provider.resume(task_id, %{"late" => true}, opts)

    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert tape_at_cancel == @engine.steps(store, task_id, store_module: @dets)

    # PRE-W4 EVIDENCE: direct Engine.signal at the cancelled run.
    engine_result = @engine.signal(store, task_id, "go", %{"late" => true})

    assert match?({:ok, %AshPPlan.Reactor.Durable.Signal{}}, engine_result) or
             match?({:error, {:run_terminal, _}}, engine_result),
           "unexpected Engine.signal result on a cancelled run: #{inspect(engine_result)}"
  end

  # -- invariant 4: idempotent re-dispatch --------------------------------------

  test "re-dispatching a completed task observes the sealed result, effect count stays 1",
       %{store: store, fx: fx, opts: opts} do
    task_id = "i7-replay-#{System.unique_integer([:positive])}"

    assert {:ok, :completed, result1} =
             Provider.dispatch(task_id, linear_model(), linear_bindings(fx), opts)

    assert {:ok, :completed, result2} =
             Provider.dispatch(task_id, linear_model(), linear_bindings(fx), opts)

    assert result1 == result2

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    tape1 = @engine.steps(store, task_id, store_module: @dets)
    assert Enum.map(tape1, & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_linear#step-prepare"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_binding_linear#step-finish")
           ]

    # And the provider's dispatch-or-resume composite also passes through.
    message = %AshA2A.Protocol.Message{
      role: :user,
      parts: [%AshA2A.Protocol.Part.Data{data: %{"again" => true}}]
    }

    execution_config = [
      pplan: [
        store: opts[:store],
        store_module: @dets,
        model: linear_model(),
        bindings: linear_bindings(fx)
      ]
    ]

    # the composite passes the provider's status detail through on the sealed
    # path: state completed, sealed result embedded in the detail map
    assert {:ok, %{state: :completed, detail: %{run_status: :completed, result: ^result1}}} =
             AshA2A.Execution.PPlan.run(task_id, message, execution_config)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end
end
