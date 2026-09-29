defmodule AshA2A.C1PreparedStore.RefusedClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "refused_claimed", do: assert Transition.admit(:refused, :claimed) == {:error, :prepared_transition_refused}
end
