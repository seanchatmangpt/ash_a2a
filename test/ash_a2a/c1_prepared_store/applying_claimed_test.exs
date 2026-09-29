defmodule AshA2A.C1PreparedStore.ApplyingClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "applying_claimed", do: assert Transition.admit(:applying, :claimed) == {:error, :prepared_transition_refused}
end
