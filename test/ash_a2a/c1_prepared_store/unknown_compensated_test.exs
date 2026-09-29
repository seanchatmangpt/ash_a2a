defmodule AshA2A.C1PreparedStore.UnknownCompensatedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "unknown_compensated", do: assert Transition.admit(:unknown_outcome, :compensated) == :ok
end
