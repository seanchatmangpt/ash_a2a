defmodule AshA2A.Providers.PPlanDurabilityTest do
  @moduledoc """
  Lane Y6 end-to-end court for `AshA2A.Providers.PPlan` over the REAL ash_pplan
  durable stack (`AshPPlan.Reactor.Durable.{Engine,Run,Status}` over a real
  disk-backed `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir). Zero mocks:
  the plan steps are real Reactor steps counting into a real named Agent, the
  park/resume hops are real `Durable.Steps.Await` signal waiters, and the
  restart leg kills the store process and reopens the same DETS file.

  Acceptance (operator directive): agent durable state works with ash_pplan —
  a run parked on an Await step survives the store process dying, and the
  provider reports it correctly before and after.

  If `:ash_pplan` cannot load in the test env, every test skips with a typed
  BLOCKED reason (`{:blocked, :ash_pplan_not_loadable}`) printed to stderr —
  a named finding, never a silent pass.
  """

  use ExUnit.Case, async: false

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @engine AshPPlan.Reactor.Durable.Engine

  # -- real collaborators ------------------------------------------------------

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect records exactly here."
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
    @moduledoc "Counting Reactor step; `options[:effect]` names the counter."
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
    Test adapter: counting effects plus ash_pplan's own Await/Poll durable steps.
    Realization options carry the per-test `:effects` agent name (data, survives
    a store round trip).
    """

    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_durability_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await, :state_hold]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]},
        state_hold:
          {Steps.Poll,
           [until: {AshPPlan.Reactor.Adapters.Durable, :argument_until, [:ready]}, every: 3_600_000]}
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
      Map.put(Map.new(previous), :a2a_durability_fx, Adapter)
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

  defp simple_model,
    do:
      model("a2a_durability_simple", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :finish, capability: "Process.Finish", depends_on: [:prepare]]
      ])

  defp await_model,
    do:
      model("a2a_durability_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
      ])

  defp poll_model,
    do:
      model("a2a_durability_poll", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :hold, capability: "State.Hold", depends_on: [:prepare]]
      ])

  defp bindings(effects) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:finish, "Process.Finish"},
      {:await, "Event.Await"},
      {:hold, "State.Hold"}
    ]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :a2a_durability_fx,
         binding: %{adapter: :a2a_durability_fx, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp open_store do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-laneY6-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path)
    # the restart court kills the store; a live link would take the test down with it
    Process.unlink(store)
    %{store: store, path: path}
  end

  setup do
    unless AshA2A.Providers.PPlan.available?() do
      reason = {:blocked, :ash_pplan_not_loadable}

      IO.puts(:stderr, "[lane-y6] BLOCKED: :ash_pplan did not load in the test env")

      {:skip, reason}
    end

    install_adapter!()
    {:ok, fx} = Effects.start_link(:"pplan_durability_fx_#{System.unique_integer([:positive])}")
    %{store: store, path: path} = open_store()

    %{store: store, path: path, fx: fx, sm: @dets, opts: [store: store, store_module: @dets]}
  end

  # -- (a) idempotent dispatch (moduledoc falsifier #1) ------------------------

  test "dispatch/4 re-dispatch of the same task id adopts the run: no tape growth, no re-execution",
       %{store: store, fx: fx, opts: opts} do
    task_id = "a2a-task-idem-1"
    model = simple_model()

    assert {:ok, :completed, result1} =
             AshA2A.Providers.PPlan.dispatch(task_id, model, bindings(fx), opts)

    tape0 = @engine.steps(store, task_id, store_module: @dets)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # Re-dispatch: same task id, same plan.
    assert {:ok, :completed, ^result1} =
             AshA2A.Providers.PPlan.dispatch(task_id, model, bindings(fx), opts)

    tape1 = @engine.steps(store, task_id, store_module: @dets)
    assert length(tape1) == length(tape0)
    assert Enum.map(tape1, & &1.step_key) == Enum.map(tape0, & &1.step_key)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end

  # -- (b) park on Await -> :input_required; resume completes ------------------

  test "await park reports :input_required, resume delivers a consume-once signal and completes",
       %{store: store, fx: fx, opts: opts} do
    task_id = "a2a-task-await-1"

    assert {:ok, :input_required, ["go"]} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(fx), opts)

    assert {:ok, :input_required,
            %{run_status: :waiting, waiters: ["go"], version: v_parked, error: nil}} =
             AshA2A.Providers.PPlan.status(task_id, opts)

    assert {:ok, :completed, _result} = AshA2A.Providers.PPlan.resume(task_id, %{answer: 42}, opts)

    # exactly one signal was delivered and it was consumed exactly once
    assert [%{name: "go", consumed_at: consumed}] = @dets.signals(store, task_id)
    refute is_nil(consumed)

    # the delivered payload reached the plan as the Await step's output (finish ran once,
    # prepare never re-ran)
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert {:ok, :completed, %{run_status: :completed, version: v_done, waiters: []}} =
             AshA2A.Providers.PPlan.status(task_id, opts)

    assert v_done > v_parked
  end

  test "second resume on the terminal run returns the sealed state and moves nothing",
       %{fx: fx, opts: opts} do
    task_id = "a2a-task-await-2"

    assert {:ok, :input_required, _} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(fx), opts)

    assert {:ok, :completed, result} = AshA2A.Providers.PPlan.resume(task_id, 1, opts)

    assert {:ok, :completed, %{version: v}} = AshA2A.Providers.PPlan.status(task_id, opts)

    # a second resume consumes nothing and the terminal state does not move
    assert {:ok, :completed, ^result} = AshA2A.Providers.PPlan.resume(task_id, 2, opts)

    assert {:ok, :completed, %{version: ^v}} = AshA2A.Providers.PPlan.status(task_id, opts)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end

  test "resume on a run with no pending signal waiter is a typed refusal that moves nothing",
       %{fx: fx, opts: opts} do
    task_id = "a2a-task-poll-1"

    # a Poll-parked run is :working/:polling with no signal waiter
    assert {:ok, :working, nil} =
             AshA2A.Providers.PPlan.dispatch(task_id, poll_model(), bindings(fx), opts)

    assert {:ok, :working, %{run_status: :polling, version: v}} =
             AshA2A.Providers.PPlan.status(task_id, opts)

    assert {:error, :no_signal_waiter} = AshA2A.Providers.PPlan.resume(task_id, %{}, opts)

    assert {:ok, :working, %{run_status: :polling, version: ^v}} =
             AshA2A.Providers.PPlan.status(task_id, opts)
  end

  # -- (c) durability across restart (operator acceptance) ---------------------

  test "a parked run survives the store process being killed and the DETS file being reopened",
       %{store: store, path: path, fx: fx} do
    task_id = "a2a-task-restart-1"
    opts = [store: store, store_module: @dets]

    assert {:ok, :input_required, ["go"]} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(fx), opts)

    # kill the store process hard (no terminate/2, no graceful sync)
    Process.exit(store, :kill)
    refute Process.alive?(store)

    # reboot against the same tmp dir; the dead owner's path lock is taken over
    {:ok, store2} = @dets.start_link(path: path)
    opts2 = [store: store2, store_module: @dets]

    assert {:ok, :input_required,
            %{run_status: :waiting, waiters: ["go"], version: v_parked}} =
             AshA2A.Providers.PPlan.status(task_id, opts2)

    # the follow-up hop lands on the REBOOTED store and completes
    assert {:ok, :completed, _result} = AshA2A.Providers.PPlan.resume(task_id, %{n: 7}, opts2)

    # replay executed no step twice across the restart boundary
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert {:ok, :completed, %{run_status: :completed}} =
             AshA2A.Providers.PPlan.status(task_id, opts2)

    assert v_parked > 0
  end

  # -- (d) status mapping totality; cancel claim-CAS refusal -------------------

  test "to_state/1 is total over ash_pplan's landed status set" do
    all = AshPPlan.Reactor.Durable.Status.all()

    assert length(all) == 9

    for s <- all do
      assert {:ok, _state} = AshA2A.Providers.PPlan.to_state(s)
    end

    assert AshA2A.Providers.PPlan.to_state(:pending) == {:ok, :submitted}
    assert AshA2A.Providers.PPlan.to_state(:waiting) == {:ok, :input_required}
    assert AshA2A.Providers.PPlan.to_state(:polling) == {:ok, :working}
    assert AshA2A.Providers.PPlan.to_state(:completed) == {:ok, :completed}
    assert AshA2A.Providers.PPlan.to_state(:failed) == {:ok, :failed}
    assert AshA2A.Providers.PPlan.to_state(:cancelled) == {:ok, :canceled}
  end

  test "cancel/2 on an ended run returns the standing goal state, not an error", %{
    fx: fx,
    opts: opts
  } do
    task_id = "a2a-task-cancel-ended-1"

    assert {:ok, :completed, result} =
             AshA2A.Providers.PPlan.dispatch(task_id, simple_model(), bindings(fx), opts)

    assert {:ok, :completed, ^result} = AshA2A.Providers.PPlan.cancel(task_id, opts)
  end

  test "cancel/2 loses the claim CAS to a held migration claim and refuses typed", %{
    store: store,
    fx: fx,
    opts: opts
  } do
    task_id = "a2a-task-cancel-cas-1"

    assert {:ok, :input_required, _} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(fx), opts)

    # a live migration- claim holds the run: the store's claim CAS must refuse the cancel
    assert {:ok, _claimed} = @dets.claim(store, task_id, "migration-court-y6", 60_000, DateTime.utc_now())

    assert {:error, {:claim_held, ^task_id}} = AshA2A.Providers.PPlan.cancel(task_id, opts)

    # the run itself did not move
    assert {:ok, :input_required, %{run_status: :waiting}} =
             AshA2A.Providers.PPlan.status(task_id, opts)
  end

  # -- (e) unmapped status -> typed error --------------------------------------

  test "to_state/1 on an unmapped status is a typed refusal, never a silent default" do
    assert {:error, {:unmapped_status, :someday_status}} =
             AshA2A.Providers.PPlan.to_state(:someday_status)
  end

  # -- typed refusals on unknown runs (surfaced defect: bare :error) -----------

  test "status/2 and resume/3 on an unknown task id fail closed with {:error, :no_such_run}", %{
    opts: opts
  } do
    assert {:error, :no_such_run} = AshA2A.Providers.PPlan.status("a2a-task-never-was", opts)
    assert {:error, :no_such_run} = AshA2A.Providers.PPlan.resume("a2a-task-never-was", 1, opts)
    assert {:error, :no_such_run} = AshA2A.Providers.PPlan.cancel("a2a-task-never-was", opts)
  end
end
