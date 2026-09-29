defmodule AshA2A.C1PreparedStore.CompensatedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "compensated_applying", do: assert Transition.admit(:compensated, :applying) == {:error, :prepared_transition_refused}
end
