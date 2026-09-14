defmodule AshA2A.TaskLifecycleStateMachineTest do
  @moduledoc """
  GAP D (Squad D, agents 16-17) -- closes `AshStateMachine:
  UNSUPPORTED -> ALIVE` with real evidence.

  `:ash_state_machine` is now a real, resolvable dependency (`mix.exs`:
  `{:ash_state_machine, "~> 0.2"}`), so `AshA2A.TaskLifecycle.available?()`
  is real `true` and `lib/ash_a2a/task_lifecycle.ex`'s
  `{:error, {:unsupported, :ash_state_machine}}` degrade branch
  (`possible_next_states/2`'s `not available?()` clause) is now provably
  unreachable for a resource that genuinely carries the extension -- this
  test proves that by never hitting it.

  Three real things are proven against
  `AshA2A.Test.Fixture.StateMachineTask` (`test/support/state_machine_fixture.ex`,
  a genuine `Ash.Resource` with `extensions: [AshStateMachine]`, not a
  hand-rolled imitation):

    1. A real Ash create + real Ash update action genuinely transitions the
       real persisted `:state` attribute through the real `AshStateMachine`
       extension (`transition_state/1` builtin change), verified by
       re-reading the record from the real `Ash.DataLayer.Ets` table after
       each transition -- not just inspecting the in-memory changeset
       result.
    2. `AshA2A.TaskLifecycle.possible_next_states/2` called against the
       real fixture resource+state returns real values sourced from the
       real `AshStateMachine.possible_next_states/1,2` functions -- the
       `{:error, {:unsupported, ...}}` degrade path is asserted absent.
    3. An invalid/disallowed transition is really refused by the real
       extension: calling the `:complete` action on a record still in
       `:submitted` (skipping `:start`) produces a real
       `Ash.Error.Invalid` wrapping a real
       `AshStateMachine.Errors.NoMatchingTransition` -- not a fabricated
       error term -- and `AshA2A.TaskLifecycle.admit/3` reports the same
       real refusal via its own `{:error, {:transition_not_admitted, _}}`
       shape.

  Chicago-style throughout: a real compiled `Ash.Resource` on a real
  `Ash.DataLayer.Ets` table, real `Ash.create!/2` and
  `Ash.Changeset.for_update/3` + `Ash.update/1` calls, state-based
  assertions on the real persisted attribute and the real returned
  error/ok tuples. Zero Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.Fixture.StateMachineTask
  alias AshA2A.TaskLifecycle

  describe "real dependency availability (GAP D closure precondition)" do
    test "AshStateMachine is really loaded and AshA2A.TaskLifecycle.available?/0 is really true" do
      assert Code.ensure_loaded?(AshStateMachine)
      assert TaskLifecycle.available?() == true
    end
  end

  describe "a real Ash action genuinely transitions real persisted state via AshStateMachine" do
    test "create sets the real persisted :state to the real default_initial_state" do
      task = Ash.create!(StateMachineTask, %{})

      assert task.state == :submitted

      # Re-read from the real ETS table -- not just the in-memory create
      # result -- to confirm the state was genuinely persisted.
      reloaded = Ash.get!(StateMachineTask, task.id)
      assert reloaded.state == :submitted
    end

    test "a real :start update transitions the real persisted state from :submitted to :working" do
      task = Ash.create!(StateMachineTask, %{})
      assert task.state == :submitted

      {:ok, started} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      assert started.state == :working

      reloaded = Ash.get!(StateMachineTask, task.id)
      assert reloaded.state == :working
    end

    test "a real full submitted -> working -> completed walk persists at every real hop" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, working} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      assert working.state == :working
      assert Ash.get!(StateMachineTask, task.id).state == :working

      {:ok, completed} =
        working
        |> Ash.Changeset.for_update(:complete, %{})
        |> Ash.update()

      assert completed.state == :completed
      assert Ash.get!(StateMachineTask, task.id).state == :completed
    end

    test "a real submitted -> working -> failed walk persists the real terminal failure state" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, working} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, failed} =
        working
        |> Ash.Changeset.for_update(:fail, %{})
        |> Ash.update()

      assert failed.state == :failed
      assert Ash.get!(StateMachineTask, task.id).state == :failed
    end

    test "a real :cancel update is legal from :submitted (pre-execution cancellation)" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, canceled} =
        task
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update()

      assert canceled.state == :canceled
      assert Ash.get!(StateMachineTask, task.id).state == :canceled
    end
  end

  describe "AshA2A.TaskLifecycle.possible_next_states/2 sources real values from the real extension" do
    test "for a fresh :submitted record with no action filter, returns the real reachable states" do
      task = Ash.create!(StateMachineTask, %{})

      assert {:ok, next_states} = TaskLifecycle.possible_next_states(task)

      # Real transitions declared `from: :submitted`: :start (-> :working)
      # and :cancel (-> :canceled). Sorted so this assertion does not
      # depend on the real extension's internal enumeration order.
      assert Enum.sort(next_states) == [:canceled, :working]
    end

    test "for a fresh :submitted record filtered to the :start action, returns only :working" do
      task = Ash.create!(StateMachineTask, %{})

      assert {:ok, [:working]} = TaskLifecycle.possible_next_states(task, :start)
    end

    test "for a fresh :submitted record filtered to the :complete action, returns no real next states" do
      task = Ash.create!(StateMachineTask, %{})

      # The real :complete transition is declared `from: :working` only --
      # a :submitted record has no real matching transition for it.
      assert {:ok, []} = TaskLifecycle.possible_next_states(task, :complete)
    end

    test "for a :working record, returns the real reachable states from :working" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, working} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      assert {:ok, next_states} = TaskLifecycle.possible_next_states(working)
      assert Enum.sort(next_states) == [:canceled, :completed, :failed]
    end

    test "the {:error, {:unsupported, :ash_state_machine}} degrade path is provably unreachable here" do
      task = Ash.create!(StateMachineTask, %{})

      refute match?({:error, {:unsupported, _}}, TaskLifecycle.possible_next_states(task))
      refute match?({:error, {:unsupported, _}}, TaskLifecycle.possible_next_states(task, :start))
    end
  end

  describe "a real disallowed transition is really refused by AshStateMachine, not fabricated" do
    test "calling :complete on a :submitted record (skipping :start) raises a real Ash.Error.Invalid wrapping a real AshStateMachine.Errors.NoMatchingTransition" do
      task = Ash.create!(StateMachineTask, %{})
      assert task.state == :submitted

      result =
        task
        |> Ash.Changeset.for_update(:complete, %{})
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result

      assert Enum.any?(errors, fn
               %AshStateMachine.Errors.NoMatchingTransition{
                 old_state: :submitted,
                 target: :completed,
                 action: :complete
               } ->
                 true

               _ ->
                 false
             end)

      # The real refusal must not have mutated the real persisted state.
      assert Ash.get!(StateMachineTask, task.id).state == :submitted
    end

    test "calling :cancel on an already-:completed record is really refused (no transition leaves a terminal state)" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, working} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, completed} =
        working
        |> Ash.Changeset.for_update(:complete, %{})
        |> Ash.update()

      result =
        completed
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result

      assert Enum.any?(
               errors,
               &match?(%AshStateMachine.Errors.NoMatchingTransition{old_state: :completed}, &1)
             )
    end

    test "AshA2A.TaskLifecycle.admit/3 refuses the same real disallowed transition via its own real shape" do
      task = Ash.create!(StateMachineTask, %{})

      assert TaskLifecycle.admit(task, :completed, :complete) ==
               {:error, {:transition_not_admitted, :completed}}
    end

    test "AshA2A.TaskLifecycle.admit/3 admits a real legal transition" do
      task = Ash.create!(StateMachineTask, %{})

      assert TaskLifecycle.admit(task, :working, :start) == :ok
    end
  end
end
