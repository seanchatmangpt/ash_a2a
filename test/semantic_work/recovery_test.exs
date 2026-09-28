defmodule AshA2A.SemanticWork.RecoveryTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Recovery

  test "requires subject-bound input" do
    assert {:error, _} = Recovery.bind(%{})
    assert {:error, :refused_invalid_envelope} = Recovery.bind(nil)
  end
end
