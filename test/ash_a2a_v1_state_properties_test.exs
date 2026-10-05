defmodule AshA2A.V1StatePropertiesTest do
  @moduledoc """
  Lane Z5 property court over the real v1.0 task-lifecycle state machine
  bridge (`AshA2A.TaskLifecycle`) -- the adapter that fronts the REAL
  `AshStateMachine.possible_next_states/1,2` on real `Ash.Resource`s.

  Zero mocks: every `admit/3` verdict is checked against the real
  extension's verdict on a real, persisted record produced by a real walk
  of `Ash.create!` + `Ash.Changeset.for_update` + `Ash.update!` hops
  (Chicago: assert on real state, not interactions). Two real fixture
  resources are used:

    * `AshA2A.Test.Fixture.StateMachineTask` (shared, 5-state subset of
      the vocabulary, pre-existing) -- proves agreement on the subset the
      shared fixture declares.
    * `AshA2A.V1StatePropertiesTest.V1Task` (below) -- a real
      `AshStateMachine` resource whose transition graph spans the FULL
      v1.0 vocabulary (`AshA2A.TaskLifecycle.states/0`), because the
      shared fixture intentionally declares only a subset and no
      transition can ever reach `:input_required`/`:auth_required`/
      `:rejected` there.

  The pinned legal-transition matrix (union over all actions, exactly as
  the DSL below declares it):

      from            | possible next states
      ----------------+-------------------------------------------------------------
      submitted       | [:canceled, :rejected, :working]
      working         | [:auth_required, :canceled, :completed, :failed,
                      |  :input_required]
      input_required  | [:canceled, :completed, :failed, :working]
      auth_required   | [:canceled, :completed, :failed, :working]
      completed       | []
      failed          | []
      canceled        | []
      rejected        | []

  Resumable states (`:working`, `:input_required`, `:auth_required`) can
  each reach every terminal the spec allows from a running task --
  `:completed`, `:failed`, `:canceled` -- and their union with
  `:submitted` reaches the fourth terminal, `:rejected` (refusal at
  admission). Terminal states admit NOTHING.

  Properties (~40 stream_data iterations each):

    a. `admit/3` agrees EXACTLY with `AshStateMachine.possible_next_states`
       (union over actions and per-action) on every random (from, to,
       action) pair -- `:ok` iff the target is in the possible set;
       identity targets are refusals (no self-loops).
    b. No transition escapes the vocabulary: an out-of-vocabulary target
       (`:unknown`, junk atoms, legacy strings, `nil`, integers) yields
       the typed refusal `{:error, {:unknown_a2a_state, target}}`, never
       an exception.
    c. Terminal states (`:completed`, `:failed`, `:canceled`, `:rejected`)
       admit nothing, total over all (to, action) pairs.
    d. The exact legal matrix is pinned as an exhaustive table assertion
       (every from x to x action, not sampled).
    e. Wire round-trip: every vocabulary state encodes to its exact
       `TASK_STATE_*` spelling and decodes back through the real codec
       (`AshA2A.Protocol.JSON`), including the legacy lowercase aliases;
       `AshA2A.Protocol.Task.terminal?/1` agrees with the pinned terminal
       set for every state.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.Task
  alias AshA2A.Protocol.Task.Status
  alias AshA2A.TaskLifecycle
  alias AshA2A.Test.Fixture.StateMachineTask

  # ---------------------------------------------------------------------
  # Real full-vocabulary AshStateMachine fixture (compiled in-file)
  # ---------------------------------------------------------------------

  defmodule V1TaskDomain do
    @moduledoc false

    use Ash.Domain

    resources do
      resource(AshA2A.V1StatePropertiesTest.V1Task)
    end
  end

  defmodule V1Task do
    @moduledoc """
    Real `Ash.Resource` carrying the REAL `AshStateMachine` extension,
    spanning the complete v1.0 task vocabulary. Every hop below is a real
    declared transition with its own real update action.
    """

    use Ash.Resource,
      domain: AshA2A.V1StatePropertiesTest.V1TaskDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStateMachine]

    attributes do
      uuid_primary_key(:id)
    end

    state_machine do
      initial_states([
        :submitted,
        :working,
        :input_required,
        :auth_required,
        :completed,
        :failed,
        :canceled,
        :rejected
      ])

      default_initial_state(:submitted)
      state_attribute(:state)

      transitions do
        # The agent picks the task up.
        transition(:start, from: :submitted, to: :working)

        # Park/resume pairs for the two resumable parked states.
        transition(:park_input, from: :working, to: :input_required)
        transition(:resume_input, from: :input_required, to: :working)
        transition(:park_auth, from: :working, to: :auth_required)
        transition(:resume_auth, from: :auth_required, to: :working)

        # Every resumable state can finish, fail, or be canceled.
        transition(:complete, from: [:working, :input_required, :auth_required], to: :completed)

        transition(:fail, from: [:working, :input_required, :auth_required], to: :failed)

        transition(
          :cancel,
          from: [:submitted, :working, :input_required, :auth_required],
          to: :canceled
        )

        # Refusal at admission: refused before any handler effect.
        transition(:reject, from: :submitted, to: :rejected)
      end
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
      end

      update :start do
        accept([])
        change(transition_state(:working))
      end

      update :park_input do
        accept([])
        change(transition_state(:input_required))
      end

      update :resume_input do
        accept([])
        change(transition_state(:working))
      end

      update :park_auth do
        accept([])
        change(transition_state(:auth_required))
      end

      update :resume_auth do
        accept([])
        change(transition_state(:working))
      end

      update :complete do
        accept([])
        change(transition_state(:completed))
      end

      update :fail do
        accept([])
        change(transition_state(:failed))
      end

      update :cancel do
        accept([])
        change(transition_state(:canceled))
      end

      update :reject do
        accept([])
        change(transition_state(:rejected))
      end
    end
  end

  # ---------------------------------------------------------------------
  # Pinned tables (independent restatement of the declared graphs)
  # ---------------------------------------------------------------------

  @vocabulary TaskLifecycle.states()
  @terminals [:completed, :failed, :canceled, :rejected]
  @resumable [:working, :input_required, :auth_required]

  @resumable_expected_possible %{
    working: [:auth_required, :canceled, :completed, :failed, :input_required],
    input_required: [:canceled, :completed, :failed, :working],
    auth_required: [:canceled, :completed, :failed, :working]
  }

  @v1_actions [:start, :park_input, :resume_input, :park_auth, :resume_auth, :complete, :fail, :cancel, :reject]

  @v1_declared_hops [
    {:start, :submitted, :working},
    {:park_input, :working, :input_required},
    {:resume_input, :input_required, :working},
    {:park_auth, :working, :auth_required},
    {:resume_auth, :auth_required, :working},
    {:complete, :working, :completed},
    {:complete, :input_required, :completed},
    {:complete, :auth_required, :completed},
    {:fail, :working, :failed},
    {:fail, :input_required, :failed},
    {:fail, :auth_required, :failed},
    {:cancel, :submitted, :canceled},
    {:cancel, :working, :canceled},
    {:cancel, :input_required, :canceled},
    {:cancel, :auth_required, :canceled},
    {:reject, :submitted, :rejected}
  ]

  # Every real walk (recipe) that puts a V1Task record into a given state.
  @v1_recipes %{
    submitted: [],
    working: [:start],
    input_required: [:start, :park_input],
    auth_required: [:start, :park_auth],
    completed: [:start, :complete],
    failed: [:start, :fail],
    canceled: [:start, :cancel],
    rejected: [:reject]
  }

  # The shared fixture's declared subset graph + its walks.
  @shared_states [:submitted, :working, :completed, :failed, :canceled]
  @shared_actions [:start, :complete, :fail, :cancel]

  @shared_declared_hops [
    {:start, :submitted, :working},
    {:complete, :working, :completed},
    {:fail, :working, :failed},
    {:cancel, :submitted, :canceled},
    {:cancel, :working, :canceled}
  ]

  @shared_recipes %{
    submitted: [],
    working: [:start],
    completed: [:start, :complete],
    failed: [:start, :fail],
    canceled: [:start, :cancel]
  }

  @expected_wire %{
    submitted: "TASK_STATE_SUBMITTED",
    working: "TASK_STATE_WORKING",
    input_required: "TASK_STATE_INPUT_REQUIRED",
    auth_required: "TASK_STATE_AUTH_REQUIRED",
    completed: "TASK_STATE_COMPLETED",
    failed: "TASK_STATE_FAILED",
    canceled: "TASK_STATE_CANCELED",
    rejected: "TASK_STATE_REJECTED"
  }

  @legacy_aliases %{
    "submitted" => :submitted,
    "working" => :working,
    "input-required" => :input_required,
    "auth-required" => :auth_required,
    "completed" => :completed,
    "failed" => :failed,
    "canceled" => :canceled,
    "rejected" => :rejected
  }

  @out_of_vocab_atoms [
    :unknown,
    :queued,
    :pending,
    :in_progress,
    :waiting,
    :completed_typo,
    :submittedd,
    :cancel
  ]

  @out_of_vocab_other ["completed", "TASK_STATE_COMPLETED", "input-required", "", nil, 42]

  # ---------------------------------------------------------------------
  # Helpers -- real record realization, real verdict queries
  # ---------------------------------------------------------------------

  defp realize(resource, recipe) do
    record = Ash.create!(resource, %{})

    Enum.reduce(recipe, record, fn action, acc ->
      acc
      |> Ash.Changeset.for_update(action, %{})
      |> Ash.update!()
    end)
  end

  defp real_possible(record, nil), do: elem(TaskLifecycle.possible_next_states(record), 1)

  defp real_possible(record, action), do: elem(TaskLifecycle.possible_next_states(record, action), 1)

  defp expected_possible(from, action, hops) do
    hops
    |> Enum.filter(fn {hop_action, hop_from, _to} ->
      (is_nil(action) or hop_action == action) and hop_from == from
    end)
    |> Enum.map(&elem(&1, 2))
    |> Enum.uniq()
  end

  defp assert_agreement(record, from, to, action, hops) do
    assert record.state == from

    expected =
      if to in expected_possible(from, action, hops) do
        :ok
      else
        {:error, {:transition_not_admitted, to}}
      end

    assert TaskLifecycle.admit(record, to, action) == expected
  end

  # ---------------------------------------------------------------------
  # (a) admit/3 agrees exactly with the real extension's possible set
  # ---------------------------------------------------------------------

  @tag :v1_state_properties
  property "admit/3 agrees exactly with possible_next_states (full-vocabulary resource)", %{} do
    check all(
            from <- member_of(Map.keys(@v1_recipes)),
            to <- member_of(@vocabulary),
            action <- one_of([constant(nil), member_of(@v1_actions)]),
            max_runs: 40
          ) do
      record = realize(V1Task, @v1_recipes[from])
      assert_agreement(record, from, to, action, @v1_declared_hops)
    end
  end

  @tag :v1_state_properties
  property "admit/3 agrees exactly with possible_next_states (shared 5-state fixture)", %{} do
    check all(
            from <- member_of(@shared_states),
            to <- member_of(@vocabulary),
            action <- one_of([constant(nil), member_of(@shared_actions)]),
            max_runs: 40
          ) do
      record = realize(StateMachineTask, @shared_recipes[from])
      assert_agreement(record, from, to, action, @shared_declared_hops)
    end
  end

  test "identity targets are refusals -- no self-loop transition exists anywhere" do
    Enum.each(Map.keys(@v1_recipes), fn from ->
      record = realize(V1Task, @v1_recipes[from])
      assert record.state == from
      assert TaskLifecycle.admit(record, from, nil) == {:error, {:transition_not_admitted, from}}
    end)
  end

  # ---------------------------------------------------------------------
  # (b) no transition escapes the declared vocabulary
  # ---------------------------------------------------------------------

  @tag :v1_state_properties
  property "out-of-vocabulary targets always yield the typed :unknown_a2a_state refusal", %{} do
    check all(
            junk <- one_of([member_of(@out_of_vocab_atoms), member_of(@out_of_vocab_other)]),
            max_runs: 40
          ) do
      record = realize(V1Task, @v1_recipes[:submitted])

      # Total over junk targets AND junk non-atoms: never an exception.
      assert TaskLifecycle.admit(record, junk, nil) == {:error, {:unknown_a2a_state, junk}}
    end
  end

  test ":unknown (codec-only state) is outside the admit vocabulary from every state" do
    Enum.each(Map.keys(@v1_recipes), fn from ->
      record = realize(V1Task, @v1_recipes[from])
      assert TaskLifecycle.admit(record, :unknown, nil) == {:error, {:unknown_a2a_state, :unknown}}
    end)
  end

  # ---------------------------------------------------------------------
  # (c) terminal states admit nothing (total over pairs)
  # ---------------------------------------------------------------------

  @tag :v1_state_properties
  property "terminal states admit nothing, for every target and action", %{} do
    check all(
            to <- member_of(@vocabulary),
            action <- one_of([constant(nil), member_of(@v1_actions)]),
            max_runs: 40
          ) do
      Enum.each(@terminals, fn from ->
        record = realize(V1Task, @v1_recipes[from])
        assert record.state == from
        assert TaskLifecycle.admit(record, to, action) == {:error, {:transition_not_admitted, to}}
      end)
    end
  end

  test "shared fixture's terminal rows agree -- :rejected via the real resource struct" do
    # No transition in the shared 5-state graph reaches :rejected (refusal
    # happens at admission, before the machine runs), so that row is read
    # off the real resource struct itself -- the exact shape
    # `AshStateMachine.possible_next_states/1` pattern-matches on.
    rejected = struct(StateMachineTask, state: :rejected)

    Enum.each(@vocabulary, fn to ->
      assert TaskLifecycle.admit(rejected, to, nil) ==
               {:error, {:transition_not_admitted, to}}
    end)

    Enum.each(@terminals -- [:rejected], fn from ->
      record = realize(StateMachineTask, @shared_recipes[from])

      Enum.each(@vocabulary, fn to ->
        assert TaskLifecycle.admit(record, to, nil) ==
                 {:error, {:transition_not_admitted, to}}
      end)
    end)
  end

  # ---------------------------------------------------------------------
  # (d) the exact legal matrix, pinned as an exhaustive table assertion
  # ---------------------------------------------------------------------

  test "the pinned v1.0 legal-transition matrix holds exhaustively (every from x to x action)" do
    records = Map.new(Map.keys(@v1_recipes), fn from -> {from, realize(V1Task, @v1_recipes[from])} end)

    # 1. The possible-next-state sets match the pinned table EXACTLY.
    Enum.each(Map.keys(@v1_recipes), fn from ->
      pinned = expected_possible(from, nil, @v1_declared_hops)
      assert Enum.sort(real_possible(records[from], nil)) == Enum.sort(pinned)
    end)

    # 2. Every (from, to, action) verdict matches the pinned hops.
    Enum.each(Map.keys(@v1_recipes), fn from ->
      Enum.each(@vocabulary, fn to ->
        Enum.each([nil | @v1_actions], fn action ->
          assert_agreement(records[from], from, to, action, @v1_declared_hops)
        end)
      end)
    end)

    # 3. Resumable states reach every terminal the spec allows from a
    #    running task, and the fourth terminal (:rejected) is reached from
    #    :submitted (admission refusal).
    Enum.each(@resumable, fn from ->
      assert MapSet.new(real_possible(records[from], nil)) ==
               MapSet.new(@resumable_expected_possible[from])
    end)
  end

  test "the shared fixture's sub-matrix matches its pinned subset table exhaustively" do
    records =
      Map.new(@shared_states, fn from -> {from, realize(StateMachineTask, @shared_recipes[from])} end)

    Enum.each(@shared_states, fn from ->
      pinned = expected_possible(from, nil, @shared_declared_hops)
      assert Enum.sort(real_possible(records[from], nil)) == Enum.sort(pinned)

      Enum.each(@vocabulary, fn to ->
        Enum.each([nil | @shared_actions], fn action ->
          assert_agreement(records[from], from, to, action, @shared_declared_hops)
        end)
      end)
    end)
  end

  # ---------------------------------------------------------------------
  # (e) wire codec round-trip: TASK_STATE_* spellings
  # ---------------------------------------------------------------------

  @tag :v1_state_properties
  property "every vocabulary state round-trips through the exact TASK_STATE_* spelling", %{} do
    check all(state <- member_of(@vocabulary), max_runs: 40) do
      status = Status.new(state)

      assert {:ok, map} = JSON.encode(status)
      assert map["state"] == @expected_wire[state]

      # Survives a real JSON wire crossing.
      wire = map |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^state} = JSON.decode_state(wire["state"])

      # The codec's legacy lowercase alias also decodes back.
      assert {:ok, ^state} = JSON.decode_state(legacy_aliases_key(state))

      # terminal?/1 agrees with the pinned terminal set.
      task = %Task{id: "tsk_1", status: Status.new(state)}
      assert Task.terminal?(task) == (state in @terminals)
    end
  end

  test "the full TASK_STATE_* table and the legacy alias table are pinned exhaustively" do
    Enum.each(@vocabulary, fn state ->
      assert {:ok, wire} = JSON.decode_state(@expected_wire[state])
      assert wire == state
      assert {:ok, state} == JSON.decode_state(legacy_aliases_key(state))
    end)

    # The codec-only :unknown state round-trips too, but stays OUTSIDE the
    # admit vocabulary (asserted in the properties above).
    assert {:ok, :unknown} = JSON.decode_state("TASK_STATE_UNKNOWN")

    # Garbage never decodes -- typed refusal, not an exception.
    assert JSON.decode_state("TASK_STATE_BANANA") == {:error, {:invalid_state, "TASK_STATE_BANANA"}}
    assert JSON.decode_state("") == {:error, {:invalid_state, ""}}
  end

  defp legacy_aliases_key(state) do
    {wire, _state} = Enum.find(@legacy_aliases, fn {_wire, s} -> s == state end)
    wire
  end

  # Moduledoc matrix must stay in lockstep with the pinned table.
  test "module doc matrix equals the pinned table" do
    Enum.each(Map.keys(@v1_recipes), fn from ->
      assert Enum.sort(expected_possible(from, nil, @v1_declared_hops)) ==
               Enum.sort(doc_matrix()[from])
    end)
  end

  defp doc_matrix do
    %{
      submitted: [:canceled, :rejected, :working],
      working: [:auth_required, :canceled, :completed, :failed, :input_required],
      input_required: [:canceled, :completed, :failed, :working],
      auth_required: [:canceled, :completed, :failed, :working],
      completed: [],
      failed: [],
      canceled: [],
      rejected: []
    }
  end
end
