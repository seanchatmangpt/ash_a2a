defmodule AshA2A.C1PreparedStore.ReleasedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "released_applying",
    do: assert(Transition.admit(:released, :applying) == {:error, :prepared_transition_refused})
end
