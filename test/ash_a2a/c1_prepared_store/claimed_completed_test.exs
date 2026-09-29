defmodule AshA2A.C1PreparedStore.ClaimedCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "claimed_completed", do: assert Transition.admit(:claimed, :completed) == {:error, :prepared_transition_refused}
end
