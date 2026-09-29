defmodule AshA2A.C1PreparedStore.ApplyingReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "applying_released", do: assert Transition.admit(:applying, :released) == {:error, :prepared_transition_refused}
end
