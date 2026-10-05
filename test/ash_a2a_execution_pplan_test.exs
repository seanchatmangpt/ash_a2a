defmodule AshA2A.Test.Fixture.PPlanExec.Resource do
  @moduledoc """
  Real fixture resource for the `adapter: :pplan` execution court
  (`test/ash_a2a_execution_pplan_test.exs`). Its one `:observe` skill is the
  node-local handler: when the default adapter is selected the skill actually
  dispatches and its action body increments a real `:persistent_term` counter;
  when `adapter: :pplan` is selected the handler is never entered, so the
  counter staying at zero is action-observed evidence that no node-local
  worker executed the task.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.PPlanExec.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :probe, :map do
      run(fn _input, _context ->
        key = {__MODULE__, :skill_dispatches}
        :persistent_term.put(key, :persistent_term.get(key, 0) + 1)
        {:ok, %{probed: true}}
      end)
    end
  end

  a2a do
    skill(:probe, :probe, consequence: :observe)
  end
end

defmodule AshA2A.Test.Fixture.PPlanExec.Domain do
  @moduledoc "Real fixture domain for the pplan execution court."
  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.PPlanExec.Resource)
  end
end

defmodule AshA2A.Test.Fixture.PPlanExec.Agent do
  @moduledoc """
  Real agent with `adapter: :pplan`: async dispatch routes through the durable
  ash_pplan run instead of the node-local handler. The compile-time `pplan:`
  opts are `{m, f, a}` tuples resolved by `AshA2A.Execution.PPlan` on every
  call, so the runtime-started DETS store / model / bindings are reachable.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.PPlanExec.Resource,
    name: "pplan_exec_agent",
    execution: [
      adapter: :pplan,
      pplan: [
        store: {AshA2A.Execution.PPlanTest.Cfg, :opt, [:store]},
        store_module: AshPPlan.Reactor.Durable.Store.Dets,
        model: {AshA2A.Execution.PPlanTest.Cfg, :opt, [:model]},
        bindings: {AshA2A.Execution.PPlanTest.Cfg, :opt, [:bindings]}
      ]
    ]
end

defmodule AshA2A.Test.Fixture.PPlanExec.LocalAgent do
  @moduledoc "Real agent with the default (node-local) adapter: regression guard."
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.PPlanExec.Resource,
    name: "pplan_local_agent"
end

defmodule AshA2A.Execution.PPlanTest do
  @moduledoc """
  Lane P1 court for the `adapter: :pplan` execution-provider integration: a
  real `AshA2A.Agent` GenServer configured
  `execution: [adapter: :pplan, pplan: [...]]` routes async dispatch through a
  durable ash_pplan run keyed by the A2A task id, over the REAL ash_pplan
  stack (`AshPPlan.Reactor.Durable.{Engine,Run,Status}` over a real disk-backed
  `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir). Zero mocks.

  Acceptance: an async skill with `adapter: :pplan` → dispatched run visible
  via provider status; a follow-up message with the same task id resumes to
  COMPLETED; a node-local worker does NOT execute it (the durable run's
  checkpoint tape is the execution record, and the fixture skill's own
  action-observed dispatch counter stays at zero).

  If `:ash_pplan` cannot load in the test env, every test skips with a typed
  BLOCKED reason (`{:blocked, :ash_pplan_not_loadable}`) printed to stderr —
  the same skip discipline as the durability court
  (`test/ash_a2a_pplan_durability_test.exs`).
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Providers.PPlan, as: Provider
  alias AshA2A.Test.Fixture.PPlanExec.Agent, as: PPlanExecAgent
  alias AshA2A.Test.Fixture.PPlanExec.LocalAgent

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @engine AshPPlan.Reactor.Durable.Engine
  @adapter_id :a2a_pplan_exec_fx
  @counter_key {AshA2A.Test.Fixture.PPlanExec.Resource, :skill_dispatches}

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
    def id, do: :a2a_pplan_exec_fx

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

  defmodule Cfg do
    @moduledoc """
    Runtime config holder for the court's agent fixture: the agent's
    compile-time `pplan:` opts are `{m, f, a}` tuples resolved by
    `AshA2A.Execution.PPlan` on every call, so a runtime-started DETS store,
    model, and bindings are reachable from compile-time agent opts.
    """

    @key {:ash_a2a_pplan_exec_court, :pplan}

    def put(opts), do: :persistent_term.put(@key, opts)

    def opt(key), do: Keyword.fetch!(:persistent_term.get(@key), key)

    def stop do
      case :persistent_term.get(@key, nil) do
        %{store: store} when is_pid(store) ->
          if Process.alive?(store), do: Process.exit(store, :kill)

        _ ->
          :ok
      end

      :persistent_term.erase(@key)
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
      model("a2a_pplan_exec_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
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

  defp open_store(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-exec-laneP1-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path, name: name)
    store
  end

  setup context do
    unless AshA2A.Execution.PPlan.available?() do
      reason = {:blocked, :ash_pplan_not_loadable}

      IO.puts(:stderr, "[lane-p1] BLOCKED: :ash_pplan did not load in the test env")

      {:skip, reason}
    end

    install_adapter!()

    {:ok, fx} = Effects.start_link(:"pplan_exec_fx_#{System.unique_integer([:positive])}")

    store = open_store(:"#{context.module}.Store")

    Cfg.put(
      store: store,
      store_module: @dets,
      model: await_model(),
      bindings: bindings(fx)
    )

    :persistent_term.put(@counter_key, 0)

    ExUnit.Callbacks.on_exit(fn ->
      Cfg.stop()
      :persistent_term.erase(@counter_key)
    end)

    %{store: store, fx: fx, opts: [store: store, store_module: @dets]}
  end

  # -- the contract ------------------------------------------------------------

  @tag :serial
  test "async dispatch parks input_required on the durable run; the same task id resumes to COMPLETED; no node-local handler runs",
       %{store: store, fx: fx, opts: opts} do
    _sup_and_registry =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [PPlanExecAgent])

    # Turn 1: fresh task -> durable run dispatched, parked on the Await step.
    assert {:ok, task1} = PPlanExecAgent.call(PPlanExecAgent, data_message(%{step: 1}))

    assert task1.status.state == :input_required
    task_id = task1.id

    # the dispatched run is visible via provider status on the SAME task id
    assert {:ok, :input_required,
            %{run_status: :waiting, waiters: ["go"], version: v_parked, error: nil}} =
             Provider.status(task_id, opts)

    # the durable run executed prepare exactly once; finish has not run
    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # no node-local handler execution: the fixture skill's own counter is zero
    assert 0 == skill_dispatches()

    # Turn 2: follow-up message with the SAME task id resumes the SAME run.
    assert {:ok, task2} =
             PPlanExecAgent.call(PPlanExecAgent, data_message(%{answer: 42}), task_id: task_id)

    assert task2.id == task_id
    assert task2.status.state == :completed

    # the run's sealed result maps to a real artifact on the completed task
    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
             task2.artifacts

    assert is_map(result)

    # provider status reports completion; each effect ran exactly once, in one run
    assert {:ok, :completed, %{run_status: :completed, version: v_done}} =
             Provider.status(task_id, opts)

    assert v_done > v_parked

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # the durable run's checkpoint tape is the execution record: three
    # standing step records, prepare -> await -> finish, in execution order
    # (labels are `inspect/1` of the step URNs, hence the embedded quotes)
    tape = @engine.steps(store, task_id, store_module: @dets)
    assert length(tape) == 3

    assert Enum.map(tape, & &1.label) == [
             ~s("urn:ash-pplan:workflow:a2a_pplan_exec_await#step-prepare"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_exec_await#step-await"),
             ~s("urn:ash-pplan:workflow:a2a_pplan_exec_await#step-finish")
           ]
  end

  test "the default adapter is untouched: a plain agent dispatches the skill locally and creates no durable run",
       %{opts: opts} do
    _sup_and_registry =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [LocalAgent])

    assert {:ok, task} = LocalAgent.call(LocalAgent, data_message(%{}))

    assert task.status.state == :completed

    # the node-local handler DID execute the skill (action-observed counter)
    assert 1 == skill_dispatches()

    # and no durable run was created for the task id
    assert {:error, :no_such_run} = Provider.status(task.id, opts)
  end

  defp skill_dispatches do
    :persistent_term.get(@counter_key, 0)
  end
end
