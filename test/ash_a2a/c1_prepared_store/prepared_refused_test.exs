defmodule AshA2A.C1PreparedStore.PreparedRefusedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "prepared_refused", do: assert Transition.admit(:prepared, :refused) == :ok
end
