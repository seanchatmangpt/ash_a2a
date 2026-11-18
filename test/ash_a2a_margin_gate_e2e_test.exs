defmodule AshA2A.Test.Fixture.MarginGate.Effects do
  @moduledoc "Real counting agent: each consequential actuation records exactly here."
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

defmodule AshA2A.Test.Fixture.MarginGate.Envelope do
  @moduledoc """
  Loads the REAL landed pack artifact
  `ggen-marketplace/packs/financial-margin-envelope/generated/margin_envelope.ex`
  (committed at 1af488694). Fail-loud: a missing artifact refuses the court --
  the generated surface is never re-implemented or stubbed here.
  """

  @pack_path "/Users/sac/ggen-marketplace/packs/financial-margin-envelope/generated/margin_envelope.ex"

  @spec module() :: module()
  def module do
    unless Code.ensure_loaded?(MarginEnvelope) do
      case Code.require_file(@pack_path) do
        [_ | _] -> :ok
        _ -> raise "margin-gate court BLOCKED: pack artifact missing at #{@pack_path}"
      end
    end

    MarginEnvelope
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.PrecheckStep do
  @moduledoc """
  The margin Pre-Check: calls the real `MarginEnvelope.admit/1` on the case's
  envelope. `{:admit, env}` proceeds with the computed gross margin as output;
  an escalation/refusal is a typed step error carrying the envelope's own
  closed breach vocabulary -- fail-closed BEFORE any downstream actuation.
  """

  use Reactor.Step

  @impl true
  def run(_arguments, _context, options) do
    envelope = Keyword.fetch!(options, :envelope)
    mod = AshA2A.Test.Fixture.MarginGate.Envelope.module()

    case mod.admit(envelope) do
      {:admit, _env} ->
        {:ok, {:admitted, mod.margin(envelope)}}

      {:escalate, kind, meta} ->
        {:error, {:margin_gate, kind, meta[:reason]}}

      {:refuse, kind} = refusal ->
        {:error, {:margin_gate, kind, refusal}}
    end
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.ActuateStep do
  @moduledoc "Downstream actuation: records exactly one real effect when it runs."

  use Reactor.Step

  @impl true
  def run(_arguments, _context, options) do
    case AshA2A.Test.Fixture.MarginGate.Effects.run(
           Keyword.fetch!(options, :effects),
           :actuation
         ) do
      {:ok, n} -> {:ok, %{actuated: true, seq: n}}
      {:error, _} = err -> err
    end
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.Adapter do
  @moduledoc """
  Real `AshPPlan.Reactor.Adapter` binding the margin Pre-Check and the
  downstream actuation step for this court.
  """

  @behaviour AshPPlan.Reactor.Adapter

  @impl true
  def id, do: :a2a_margin_gate_fx

  @impl true
  def available?, do: true

  @impl true
  def ops, do: [:process_prepare, :process_finish]

  @impl true
  def step(op, options) do
    table = %{
      process_prepare: {AshA2A.Test.Fixture.MarginGate.PrecheckStep, []},
      process_finish: {AshA2A.Test.Fixture.MarginGate.ActuateStep, []}
    }

    AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.Cfg do
  @moduledoc """
  Runtime config holder for the court's agent fixture: the agent's
  compile-time `pplan:` opts are `{m, f, a}` tuples resolved by
  `AshA2A.Execution.PPlan` on every call, so the runtime-started store,
  per-case model, and bindings are reachable from compile-time agent opts.
  """

  @key {:ash_a2a_margin_gate_e2e_court, :pplan}

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

defmodule AshA2A.Test.Fixture.MarginGate.Resource do
  @moduledoc """
  Real fixture resource for the margin-gate court. Its one `:observe` skill is
  the node-local handler; under `adapter: :pplan` the handler is never
  entered, so its real `:persistent_term` counter staying at zero is
  action-observed evidence that no node-local worker executed the task.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.MarginGate.Domain,
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

defmodule AshA2A.Test.Fixture.MarginGate.Domain do
  @moduledoc "Real fixture domain for the margin-gate court."
  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.MarginGate.Resource)
  end
end

defmodule AshA2A.Test.Fixture.MarginGate.Agent do
  @moduledoc """
  Real agent with `adapter: :pplan`: async dispatch routes through a durable
  ash_pplan run keyed by the A2A task id; the margin gate is the run's
  Pre-Check step, so a margin breach fails the task closed before the
  downstream actuation step is ever scheduled.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.MarginGate.Resource,
    name: "margin_gate_agent",
    execution: [
      adapter: :pplan,
      pplan: [
        store: {AshA2A.Test.Fixture.MarginGate.Cfg, :opt, [:store]},
        store_module: AshPPlan.Reactor.Durable.Store.Ets,
        model: {AshA2A.Test.Fixture.MarginGate.Cfg, :opt, [:model]},
        bindings: {AshA2A.Test.Fixture.MarginGate.Cfg, :opt, [:bindings]}
      ]
    ]
end

defmodule AshA2A.MarginGateE2ETest do
  @moduledoc """
  Lane I4 court: end-to-end consumer test of the margin-gated work-order
  capability manufactured by the `financial-margin-envelope` ggen-marketplace
  pack (generated `margin_envelope.ex`, committed at 1af488694).

  The REAL generated admit/escalate surface is the Pre-Check of an ash_pplan
  workflow model (margin Pre-Check -> downstream actuation), dispatched as a
  real A2A task through `AshA2A.Execution.PPlan` (`adapter: :pplan`) over the
  real ETS durable store. Assertions:

    * admit case (margin 0.28 >= floor 0.22): the task COMPLETES and the
      downstream actuation step is in the checkpoint tape;
    * escalate case (margin 0.19 < floor 0.22): the task FAILS CLOSED with
      the envelope's typed breach vocabulary (`:ESCALATE_MULTISIG`) and the
      tape holds NO downstream actuation step;
    * in both cases the node-local skill handler never runs -- the durable
      run's checkpoint tape is the execution record.

  If `:ash_pplan` cannot load in the test env, every test skips with a typed
  BLOCKED reason (same skip discipline as
  `test/ash_a2a_execution_pplan_test.exs`).
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Providers.PPlan, as: Provider
  alias AshA2A.Test.Fixture.MarginGate.{Adapter, Agent, Cfg, Effects, Envelope}
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Model

  @adapter_id :a2a_margin_gate_fx
  @ets AshPPlan.Reactor.Durable.Store.Ets
  @counter_key {AshA2A.Test.Fixture.MarginGate.Resource, :skill_dispatches}

  @admit_envelope %{
    envelope_id: "ENV-001",
    nte: Decimal.new("250000"),
    quote: Decimal.new("180000"),
    floor: Decimal.new("0.22"),
    currency: "USD"
  }

  @escalate_envelope %{
    envelope_id: "ENV-002",
    nte: Decimal.new("250000"),
    quote: Decimal.new("201500"),
    floor: Decimal.new("0.22"),
    currency: "USD"
  }

  setup context do
    unless AshA2A.Execution.PPlan.available?() do
      reason = {:blocked, :ash_pplan_not_loadable}
      IO.puts(:stderr, "[lane-i4] BLOCKED: :ash_pplan did not load in the test env")
      {:skip, reason}
    end

    # the REAL pack artifact is loadable, fail-loud otherwise
    env_mod = Envelope.module()
    assert env_mod == MarginEnvelope
    # Pre-Check semantics observed directly on the generated surface
    assert {:admit, _} = env_mod.admit(@admit_envelope)
    assert {:escalate, :ESCALATE_MULTISIG, _} = env_mod.admit(@escalate_envelope)
    assert :ESCALATE_MULTISIG in env_mod.refusals()

    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), @adapter_id, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
      :persistent_term.erase(@counter_key)
      Cfg.stop()
    end)

    :persistent_term.put(@counter_key, 0)

    {:ok, fx} =
      Effects.start_link(:"margin_gate_fx_#{System.unique_integer([:positive])}")

    {:ok, store} = @ets.start_link(name: :"#{context.module}.Store")

    %{store: store, fx: fx}
  end

  defp model(case_name) do
    {:ok, m} =
      Model.new(
        name: "margin_gate_#{case_name}",
        goal: "margin_gated_work_order",
        tasks: [
          [id: :precheck, capability: "Process.Prepare", depends_on: []],
          [id: :actuate, capability: "Process.Finish", depends_on: [:precheck]]
        ]
      )

    m
  end

  defp bindings(fx, envelope) do
    ops = [{:precheck, "Process.Prepare"}, {:actuate, "Process.Finish"}]

    Map.new(ops, fn {task, cap} ->
      # built through struct/2 (runtime __struct__ dispatch), not a struct
      # literal: `:ash_pplan` is an `only: :test` optional dep and must not be
      # required at test-file COMPILE time
      {task,
       struct(
         AshPPlan.Realization,
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [envelope: envelope, effects: fx]
       )}
    end)
  end

  defp configure!(store, fx, case_name, envelope) do
    Cfg.put(
      store: store,
      model: model(case_name),
      bindings: bindings(fx, envelope)
    )
  end

  defp tape(store, run_id) do
    Engine.steps(store, run_id, store_module: @ets)
  end

  @tag :serial
  test "admit case: margin 0.28 passes the Pre-Check, the task completes, and the downstream actuation is in the tape",
       %{store: store, fx: fx} do
    configure!(store, fx, :admit, @admit_envelope)

    _sup_and_registry =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [Agent])

    assert {:ok, task} = Agent.call(Agent, data_message(%{nte: "250000", quote: "180000"}))

    assert task.status.state == :completed

    # the gate ran on the REAL envelope, not the message payload: one real
    # downstream actuation happened
    assert Effects.count(fx, :actuation) == 1

    # no node-local handler execution: the fixture skill's counter is zero
    assert 0 == :persistent_term.get(@counter_key, 0)

    assert {:ok, :completed, %{run_status: :completed, error: nil}} =
             Provider.status(task.id, store: store, store_module: @ets)

    # the durable run's checkpoint tape is the execution record:
    # precheck -> actuate, in execution order
    steps = tape(store, task.id)
    assert length(steps) == 2

    assert Enum.map(steps, & &1.label) == [
             ~s("urn:ash-pplan:workflow:margin_gate_admit#step-precheck"),
             ~s("urn:ash-pplan:workflow:margin_gate_admit#step-actuate")
           ]

    # the admitted margin is the real computed gross margin, 0.28
    assert Enum.any?(steps, fn step ->
             case step.output do
               {:admitted, %Decimal{} = m} -> Decimal.eq?(m, Decimal.new("0.28"))
               _ -> false
             end
           end)
  end

  @tag :serial
  test "escalate case: margin 0.19 fails the task closed with the typed breach vocabulary and NO downstream actuation in the tape",
       %{store: store, fx: fx} do
    configure!(store, fx, :escalate, @escalate_envelope)

    _sup_and_registry =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [Agent])

    assert {:ok, task} = Agent.call(Agent, data_message(%{nte: "250000", quote: "201500"}))

    assert task.status.state == :failed

    # typed breach vocabulary from the envelope's closed refusal set
    assert :ESCALATE_MULTISIG in Envelope.module().refusals()

    # fail-closed BEFORE actuation: zero downstream effects
    assert Effects.count(fx, :actuation) == 0
    assert 0 == :persistent_term.get(@counter_key, 0)

    assert {:ok, :failed, %{run_status: :failed, error: error}} =
             Provider.status(task.id, store: store, store_module: @ets)

    # the engine wraps the step error in its own error class; the typed
    # breach vocabulary must survive the wrap, verbatim
    assert match?(%{class: :invalid}, error)
    rendered = inspect(error)
    assert rendered =~ "ESCALATE_MULTISIG"
    assert rendered =~ "margin below floor"
    assert rendered =~ "margin_gate"

    # the tape holds NO standing checkpoint: a failed step records no standing
    # checkpoint, so the actuation step is absent entirely -- fail-closed
    # BEFORE actuation, evidenced on the durable record
    steps = tape(store, task.id)
    assert steps == []
    refute Enum.any?(steps, &(&1.label =~ "actuate"))
  end
end
