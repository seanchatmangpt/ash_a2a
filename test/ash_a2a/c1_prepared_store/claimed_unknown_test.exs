defmodule AshA2A.C1PreparedStore.ClaimedUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "claimed_unknown", do: assert Transition.admit(:claimed, :unknown_outcome) == {:error, :prepared_transition_refused}
end
