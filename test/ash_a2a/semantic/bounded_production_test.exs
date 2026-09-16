defmodule AshA2A.Semantic.BoundedProductionTest do
  @moduledoc """
  RFC S72: a production operation MUST NOT require solving an
  unrestricted "continue reasoning until you believe you are done".

  The proofs here are executed, not described: the refusal tests drive
  real specs through the real `contract/2`, and the termination tests run
  the real bounded executor -- including against a predicate that is
  never satisfiable, which halts at the real step bound instead of
  looping.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.BoundedProduction

  # --------------------------------------------------------------------
  # The RFC S72 refusal
  # --------------------------------------------------------------------

  test "every named 'until you believe you are done' termination is refused by name" do
    assert BoundedProduction.unbounded_terminations() == [
             :model_judgment,
             :until_done,
             :until_believed_complete,
             :until_satisfied,
             :none,
             nil
           ]

    for termination <- BoundedProduction.unbounded_terminations() do
      assert {:error, %{code: :unbounded_production_operation, termination: ^termination}} =
               BoundedProduction.contract("reconcile-ledger",
                 max_steps: 100,
                 max_wall_time_ms: 1_000,
                 termination: termination
               )
    end
  end

  test "a prose description of when to stop is not a termination predicate" do
    assert {:error, %{code: :unbounded_production_operation}} =
             BoundedProduction.contract("reconcile-ledger",
               max_steps: 100,
               max_wall_time_ms: 1_000,
               termination: "keep going until the ledger looks right"
             )

    # Arity matters: a 0-arity function cannot decide anything about state.
    assert {:error, %{code: :unbounded_production_operation}} =
             BoundedProduction.contract("reconcile-ledger",
               max_steps: 100,
               max_wall_time_ms: 1_000,
               termination: fn -> true end
             )
  end

  test "an absent or non-positive bound is not a bound" do
    predicate = fn state -> state >= 3 end

    assert {:error, %{code: :unbounded_production_operation, bound: :max_steps, value: nil}} =
             BoundedProduction.contract("op", max_wall_time_ms: 1_000, termination: predicate)

    assert {:error, %{code: :unbounded_production_operation, bound: :max_wall_time_ms}} =
             BoundedProduction.contract("op", max_steps: 10, termination: predicate)

    assert {:error, %{code: :unbounded_production_operation, bound: :max_steps, value: 0}} =
             BoundedProduction.contract("op",
               max_steps: 0,
               max_wall_time_ms: 1_000,
               termination: predicate
             )
  end

  # --------------------------------------------------------------------
  # The bounded contract, admitted and executed
  # --------------------------------------------------------------------

  test "known production work reduces to a bounded contract that really terminates" do
    assert {:ok, contract} =
             BoundedProduction.contract("count-to-five",
               max_steps: 10,
               max_wall_time_ms: 1_000,
               termination: fn state -> state >= 5 end
             )

    assert contract.max_steps == 10
    assert String.length(contract.fingerprint) == 64

    assert {:ok, :terminated, 5, 5} = BoundedProduction.run(contract, &(&1 + 1), 0)
  end

  test "a contract whose goal already holds performs zero steps" do
    {:ok, contract} =
      BoundedProduction.contract("already-done",
        max_steps: 10,
        max_wall_time_ms: 1_000,
        termination: fn state -> state >= 5 end
      )

    assert {:ok, :terminated, 7, 0} = BoundedProduction.run(contract, &(&1 + 1), 7)
  end

  test "an unsatisfiable predicate still halts, at the real step bound, and says so" do
    # This is the executed form of the RFC S72 guarantee: even an
    # operation whose completion condition never becomes true terminates
    # decidably from outside, rather than running until something
    # "believes it is done".
    {:ok, contract} =
      BoundedProduction.contract("never-satisfied",
        max_steps: 25,
        max_wall_time_ms: 5_000,
        termination: fn _state -> false end
      )

    assert {:error,
            %{
              code: :bound_reached,
              bound: :max_steps,
              operation: "never-satisfied",
              limit: 25,
              steps: 25
            }} = BoundedProduction.run(contract, &(&1 + 1), 0)
  end

  test "the wall-clock bound halts a slow operation whose step count is nowhere near its ceiling" do
    {:ok, contract} =
      BoundedProduction.contract("slow-op",
        max_steps: 1_000_000,
        max_wall_time_ms: 20,
        termination: fn _state -> false end
      )

    assert {:error, %{code: :bound_reached, bound: :max_wall_time_ms, limit: 20, steps: steps}} =
             BoundedProduction.run(
               contract,
               fn state ->
                 Process.sleep(5)
                 state + 1
               end,
               0
             )

    # The real proof that wall time, not the step ceiling, stopped it.
    assert steps < 1_000_000
  end

  test "two contracts over the same real bounds fingerprint identically; different bounds do not" do
    predicate = fn state -> state end

    {:ok, a} =
      BoundedProduction.contract("op", max_steps: 5, max_wall_time_ms: 10, termination: predicate)

    {:ok, b} =
      BoundedProduction.contract("op", max_steps: 5, max_wall_time_ms: 10, termination: predicate)

    {:ok, c} =
      BoundedProduction.contract("op", max_steps: 6, max_wall_time_ms: 10, termination: predicate)

    assert a.fingerprint == b.fingerprint
    refute a.fingerprint == c.fingerprint
  end
end
