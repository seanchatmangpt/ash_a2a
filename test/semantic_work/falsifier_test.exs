defmodule AshA2A.SemanticWork.FalsifierTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Falsifier

  test "requires subject-bound input" do
    assert {:error, _} = Falsifier.bind(%{})
    assert {:error, :refused_invalid_envelope} = Falsifier.bind(nil)
  end
end
