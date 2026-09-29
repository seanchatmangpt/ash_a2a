defmodule AshA2A.C1PreparedStore.CompletedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "completed_applying",
    do: assert(Transition.admit(:completed, :applying) == {:error, :prepared_transition_refused})
end
