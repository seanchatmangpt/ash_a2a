defmodule AshA2A.C1PreparedStore.PreparedCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "prepared_completed", do: assert Transition.admit(:prepared, :completed) == {:error, :prepared_transition_refused}
end
