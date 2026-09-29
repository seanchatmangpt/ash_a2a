defmodule AshA2A.C1PreparedStore.ApplyingUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "applying_unknown", do: assert(Transition.admit(:applying, :unknown_outcome) == :ok)
end
