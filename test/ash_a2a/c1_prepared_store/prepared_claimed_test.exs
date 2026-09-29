defmodule AshA2A.C1PreparedStore.PreparedClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "prepared_claimed", do: assert(Transition.admit(:prepared, :claimed) == :ok)
end
