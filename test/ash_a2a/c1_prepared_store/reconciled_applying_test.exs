defmodule AshA2A.C1PreparedStore.ReconciledApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "reconciled_applying",
    do: assert(Transition.admit(:reconciled, :applying) == {:error, :prepared_transition_refused})
end
