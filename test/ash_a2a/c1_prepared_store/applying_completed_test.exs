defmodule AshA2A.C1PreparedStore.ApplyingCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "applying_completed", do: assert Transition.admit(:applying, :completed) == :ok
end
