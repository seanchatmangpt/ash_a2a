defmodule AshA2A.C1PreparedStore.ClaimedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "claimed_applying", do: assert Transition.admit(:claimed, :applying) == :ok
end
