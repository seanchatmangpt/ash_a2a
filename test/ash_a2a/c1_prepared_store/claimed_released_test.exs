defmodule AshA2A.C1PreparedStore.ClaimedReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "claimed_released", do: assert Transition.admit(:claimed, :released) == :ok
end
