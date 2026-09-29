defmodule AshA2A.C1PreparedStore.UnknownCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "unknown_completed",
    do:
      assert(
        Transition.admit(:unknown_outcome, :completed) == {:error, :prepared_transition_refused}
      )
end
