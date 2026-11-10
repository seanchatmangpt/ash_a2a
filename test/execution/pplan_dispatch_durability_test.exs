defmodule AshA2A.Execution.PPlanDispatch.KillStore do
  @moduledoc """
  Kill-injection store (lane I2): a hand-written real `AshPPlan.Reactor.Durable.Store`
  that delegates every callback to the REAL `AshPPlan.Reactor.Durable.Store.Dets`
  process on a tmp path and, when armed, kills the attempt process outright at
  the checkpoint boundary (`Process.exit(victim, :kill)`). Nothing is stubbed or
  call-counted; all run state lives in the real DETS file. The kill plan lives
  in a named Agent so it is data shared by the test and the (killed) attempt.

  The arm window sits immediately BEFORE the checkpoint is delegated to Dets:
  the step's effect has executed, its checkpoint is not persisted. Intent
  rows (`$intent:*`) pass UNARMED, so the window stays post-effect pre-record.
  Upstream ash_pplan closed this window for token-adopting steps: the
  checkpointed wrapper checkpoints the deterministic intent token before the
  effect, and a step that derives its external idempotency key from
  `context.durable_intent_token` dedupes across the crash+resume.
  """

  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.Store.Dets

  @plan __MODULE__.Plan

  def start_plan do
    Agent.start_link(fn -> :unarmed end, name: @plan)
  end

  @doc "Arm one kill: the `victim` process dies at its next checkpoint boundary."
  def arm(victim) do
    Agent.update(@plan, fn _ -> {:armed, victim, false} end)
  end

  def fired? do
    Agent.get(@plan, fn
      {:armed, _, fired} -> fired
      _ -> false
    end)
  end

  def disarm do
    case Process.whereis(@plan) do
      nil -> :ok
      _pid -> Agent.update(@plan, fn _ -> :unarmed end)
    end
  end

  defp point do
    victim =
      Agent.get_and_update(@plan, fn
        {:armed, v, false} -> {v, {:armed, v, true}}
        state -> {nil, state}
      end)

    if victim do
      if victim == self() do
        Process.exit(self(), :kill)
      else
        Process.exit(victim, :kill)
        Process.sleep(:infinity)
      end
    end

    :ok
  end

  @impl true
  def start_run(s, a), do: Dets.start_run(s, a)

  @impl true
  def get_run(s, id), do: Dets.get_run(s, id)

  @impl true
  def list_runs(s), do: Dets.list_runs(s)

  @impl true
  def transition(s, id, from, to, attrs), do: Dets.transition(s, id, from, to, attrs)

  @impl true
  def claim(s, id, claimer, lease, now), do: Dets.claim(s, id, claimer, lease, now)

  @impl true
  def release_claim(s, id, claimer), do: Dets.release_claim(s, id, claimer)

  @impl true
  def checkpoints(s, id), do: Dets.checkpoints(s, id)

  @impl true
  def standing(s, id), do: Dets.standing(s, id)

  @impl true
  def snapshot(s, id), do: Dets.snapshot(s, id)

  @impl true
  def record(s, id, key, label, output, meta) do
    # Intent rows (`$intent:*`) are metadata, not outputs — the arm window
    # stays post-effect pre-record (FenceKill idiom in ash_pplan's
    # replay_fence court: the boundary fires only on OUTPUT records).
    unless is_binary(label) and String.starts_with?(label, "$intent") do
      point()
    end

    Dets.record(s, id, key, label, output, meta)
  end

  @impl true
  def claim_undo(s, id, key, now), do: Dets.claim_undo(s, id, key, now)

  @impl true
  def mark_undone(s, id, key, now), do: Dets.mark_undone(s, id, key, now)

  @impl true
  def take_signal(s, id, name, step_key, label, meta, now),
    do: Dets.take_signal(s, id, name, step_key, label, meta, now)

  @impl true
  def release_undo(s, id, key), do: Dets.release_undo(s, id, key)

  @impl true
  def deliver_signal(s, id, name, payload), do: Dets.deliver_signal(s, id, name, payload)

  @impl true
  def pending_signal(s, id, name), do: Dets.pending_signal(s, id, name)

  @impl true
  def consume_signal(s, sid, now), do: Dets.consume_signal(s, sid, now)

  @impl true
  def park(s, id, name, kind, deadline, opts \\ []) do
    Dets.park(s, id, name, kind, deadline, opts)
  end

  @impl true
  def get_waiter(s, id, name), do: Dets.get_waiter(s, id, name)

  @impl true
  def waiters(s, id), do: Dets.waiters(s, id)

  @impl true
  def release(s, id, name), do: Dets.release(s, id, name)

  @impl true
  def release_all(s, id), do: Dets.release_all(s, id)

  @impl true
  def signals(s, id), do: Dets.signals(s, id)
end

defmodule AshA2A.Execution.PPlanDispatchDurabilityTest do
  @moduledoc """
  Lane I2 crash-resilient task-dispatch court over `AshA2A.Execution.PPlan`:
  the A2A task id IS the durable ash_pplan run id, exercised over the REAL
  ash_pplan stack (`AshPPlan.Reactor.Durable.Engine` over a real disk-backed
  `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir). Zero mocks.

  Contract (one court per clause):

    1. a fresh task id starts the run and attempts it exactly once (a re-call
       with the same task id adopts, never re-attempts);
    2. a follow-up message with the same task id resumes the SAME run via the
       parked Await signal;
    3. a still-parked deadline (`:polling`) run is passed through untouched by
       a follow-up message — never re-attempted, never reported
       `:input_required`;
    4. kill between effect and checkpoint, then resume by task id: zero
       duplicate skill execution and exactly one run in the tape. CLOSED
       (lane F16, 2026-11-07): upstream ash_pplan landed intent-before-effect
       (`Checkpointed.run_inner` writes/adopts a `$intent` row carrying the
       deterministic `Key.intent_id/2` token before the effect; the token
       returns UNCHANGED on the replay — `Run.record_intent` insert-or-adopt),
       and this court's steps now adopt it as their external idempotency key
       (kill arm fires only on OUTPUT records; intent rows pass unarmed, so
       the window exercised is the genuine post-effect pre-record crash).
       Residual (documented, honest): an effect that IGNORES the token stays
       at-least-once — see ash_pplan's replay_fence court "token-ignoring
       step duplicates" test.
  """

  use ExUnit.Case, async: false

  @moduletag :pplan_court

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Execution.PPlan, as: PPlanAdapter
  alias AshA2A.Execution.PPlanDispatch.KillStore
  alias AshA2A.Providers.PPlan, as: Provider

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @engine AshPPlan.Reactor.Durable.Engine
  @clock AshPPlan.Reactor.Durable.Clock
  @adapter_id :a2a_pplan_dispatch_fx
  @lease_lapse_ms 3_600_000

  # -- real collaborators ------------------------------------------------------

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect records exactly here."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, {token, effect}) when is_binary(token) do
      Agent.get_and_update(server, fn s ->
        key = {:executed, token, effect}

        if Map.has_key?(s, key) do
          # Intent-token dedupe: this (token, effect) already executed on a
          # prior attempt — replay the recorded result, do NOT re-execute.
          n = Map.fetch!(s, key)
          {{:ok, n}, s}
        else
          n = Map.get(s, effect, 0) + 1
          s = s |> Map.put(key, n) |> Map.put(effect, n)
          {{:ok, n}, s}
        end
      end)
    end

    def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
  end

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effects]` names the counter agent."
    use Reactor.Step

    @impl true
    def run(_arguments, context, options) do
      effects = Keyword.fetch!(options, :effects)
      effect = Keyword.fetch!(options, :effect)

      # The checkpointed wrapper's intent contract: the deterministic intent
      # token IS the external idempotency key. Fail loud if the wrap was lost.
      token = Map.fetch!(context, :durable_intent_token)

      case Effects.run(effects, {token, effect}) do
        {:ok, n} -> {:ok, {effect, n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule PollUntil do
    @moduledoc "Real poll predicate: never satisfied inside the court's window."

    def not_yet_forever(_arguments, _context), do: :not_yet
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus ash_pplan's own Await and Poll durable
    steps. Realization options carry the per-test `:effects` agent name (plain
    data, survives a store round trip).
    """

    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_pplan_dispatch_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await, :event_poll]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]},
        event_poll: {Steps.Poll, [until: {PollUntil, :not_yet_forever, []}, every: 60_000]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  defmodule Cfg do
    @moduledoc """
    Runtime config holder for the court: the adapter opts resolve `{m, f, a}`
    tuples on every call so a runtime-started DETS store / model / bindings are
    reachable (same idiom as the lane-P1 execution court).
    """

    @key {:ash_a2a_pplan_dispatch_court, :pplan}

    def put(opts), do: :persistent_term.put(@key, opts)

    def opt(key), do: Keyword.fetch!(:persistent_term.get(@key), key)

    def stop do
      case :persistent_term.get(@key, nil) do
        %{store: store} ->
          if is_pid(store) and Process.alive?(store) do
            Process.exit(store, :kill)
          end

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

  defp await_tasks do
    [
      [id: :prepare, capability: "Process.Prepare", depends_on: []],
      [id: :await, capability: "Event.Await", depends_on: [:prepare]],
      [id: :finish, capability: "Process.Finish", depends_on: [:await]]
    ]
  end

  defp poll_tasks do
    [
      [id: :prepare, capability: "Process.Prepare", depends_on: []],
      [id: :poll, capability: "Event.Poll", depends_on: [:prepare]]
    ]
  end

  defp bindings(effects, tasks) do
    Map.new(tasks, fn task ->
      cap = Keyword.fetch!(task, :capability)

      {Keyword.fetch!(task, :id),
       %AshPPlan.Realization{
         capability: cap,
         provider: @adapter_id,
         binding: %{adapter: @adapter_id, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp open_store do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-dispatch-laneI2-#{System.unique_integer([:positive])}"
      )

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path)
    store
  end

  setup do
    install_adapter!()

    {:ok, fx} = Effects.start_link(:"pplan_dispatch_fx_#{System.unique_integer([:positive])}")

    store = open_store()
    @clock.use_test_clock()

    Cfg.put(
      store: store,
      store_module: @dets,
      model: model("a2a_pplan_dispatch_await", await_tasks()),
      bindings: bindings(fx, await_tasks())
    )

    ExUnit.Callbacks.on_exit(fn ->
      # Teardown race: the test's own kill point may have just taken down the
      # KillStore.Plan agent between whereis and the Agent update — the disarm
      # must never fail the test from its own teardown.
      try do
        KillStore.disarm()
      catch
        :exit, _ -> :ok
      end

      Cfg.stop()
      @clock.reset()
    end)

    %{store: store, fx: fx}
  end

  defp cfg(store, fx, tasks, extra) do
    [
      pplan:
        [
          store: store,
          store_module: @dets,
          model: model("a2a_pplan_dispatch_await", tasks),
          bindings: bindings(fx, tasks)
        ] ++ extra
    ]
  end

  defp await_cfg(store, fx, extra \\ []) do
    cfg(store, fx, await_tasks(), extra)
  end

  defp poll_cfg(store, fx), do: cfg(store, fx, poll_tasks(), [])

  defp assert_single_run(store, task_id) do
    runs = @dets.list_runs(store)
    assert length(runs) == 1
    assert hd(runs).id == task_id
  end

  # -- the contract ------------------------------------------------------------

  @tag :serial
  test "fresh task id: run started and attempted exactly once; a re-call adopts, never re-attempts",
       %{store: store, fx: fx} do
    task_id = "i2-fresh-#{System.unique_integer([:positive])}"

    assert {:ok, first} = PPlanAdapter.run(task_id, data_message(%{step: 1}), await_cfg(store, fx))
    assert first.state == :input_required

    assert {:ok, :input_required,
            %{run_status: :waiting, waiters: ["go"], error: nil}} =
             Provider.status(task_id, store: store, store_module: @dets)

    assert %{prepare: 1, finish: 0} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # the standing tape holds the one executed step
    assert length(@engine.steps(store, task_id)) == 1

    # a re-call with the SAME task id adopts the run and delivers the payload
    # as the parked Await signal — the SAME run resumes, never re-attempted
    assert {:ok, second} = PPlanAdapter.run(task_id, data_message(%{step: 2}), await_cfg(store, fx))
    assert second.state == :completed

    # prepare ran exactly once across both calls; finish once, in the same run
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert_single_run(store, task_id)

    tape = @engine.steps(store, task_id)
    assert length(tape) == 3
  end

  @tag :serial
  test "follow-up message with the same task id resumes the SAME run via the parked Await signal",
       %{store: store, fx: fx} do
    task_id = "i2-resume-#{System.unique_integer([:positive])}"

    assert {:ok, first} = PPlanAdapter.run(task_id, data_message(%{step: 1}), await_cfg(store, fx))
    assert first.state == :input_required

    assert {:ok, :input_required, %{run_status: :waiting, waiters: ["go"]}} =
             Provider.status(task_id, store: store, store_module: @dets)

    assert {:ok, second} = PPlanAdapter.run(task_id, data_message(%{answer: 42}), await_cfg(store, fx))
    assert second.state == :completed
    assert second.detail != nil

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # one run, and its checkpoint tape holds each step exactly once in order
    assert_single_run(store, task_id)

    tape = @engine.steps(store, task_id)
    assert length(tape) == 3
    assert length(Enum.uniq_by(tape, & &1.label)) == 3
  end

  @tag :serial
  test "still-parked deadline run: passed through untouched, never re-attempted, never :input_required",
       %{store: store, fx: fx} do
    task_id = "i2-poll-#{System.unique_integer([:positive])}"

    assert {:ok, first} = PPlanAdapter.run(task_id, data_message(%{q: 1}), poll_cfg(store, fx))
    assert first.state == :working

    assert {:ok, :working, %{run_status: :polling, waiters: []}} =
             Provider.status(task_id, store: store, store_module: @dets)

    assert Effects.count(fx, :prepare) == 1

    version_before = hd(@dets.list_runs(store)).version

    # the follow-up message is refused a resume: pass-through, untouched
    assert {:ok, second} = PPlanAdapter.run(task_id, data_message(%{q: 2}), poll_cfg(store, fx))
    assert second.state == :working
    refute second.state == :input_required

    assert %{prepare: 1, finish: 0} == %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    version_after = hd(@dets.list_runs(store)).version
    assert version_before == version_after
  end

  @tag :serial
  test "kill between effect and checkpoint: resume by task id, zero duplicate execution, one run",
       %{store: store, fx: fx} do
    task_id = "i2-kill-#{System.unique_integer([:positive])}"
    {:ok, _} = KillStore.start_plan()

    kill_cfg = await_cfg(store, fx, store_module: KillStore)

    parent = self()

    {victim, ref} =
      spawn_monitor(fn ->
        PPlanAdapter.run(task_id, data_message(%{kickoff: true}), kill_cfg)
        send(parent, {:survived, task_id})
      end)

    KillStore.arm(victim)

    assert_receive {:DOWN, ^ref, :process, ^victim, :killed}, 15_000
    assert KillStore.fired?(), "kill plan never fired at the checkpoint boundary"

    # the effect executed but its checkpoint was never persisted; run non-terminal
    assert Effects.count(fx, :prepare) == 1
    assert {:ok, :submitted, %{run_status: :pending}} =
             Provider.status(task_id, store: store, store_module: @dets)

    assert @engine.steps(store, task_id) == []

    # heal: lapse the dead claim, disarm, then resume by task id
    KillStore.disarm()
    @clock.advance(@lease_lapse_ms)

    assert {:ok, resumed} = PPlanAdapter.run(task_id, data_message(%{answer: 1}), await_cfg(store, fx))
    assert resumed.state == :input_required

    assert {:ok, done} = PPlanAdapter.run(task_id, data_message(%{answer: 2}), await_cfg(store, fx))
    assert done.state == :completed

    # THE LAW: zero duplicate skill execution across the crash+resume
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # exactly one run in the tape, each step standing exactly once
    assert_single_run(store, task_id)

    tape = @engine.steps(store, task_id)
    assert length(tape) == 3
    assert length(Enum.uniq_by(tape, & &1.label)) == 3
  end
end
