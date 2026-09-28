defmodule AshA2A.SemanticWork.DeterminismTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Determinism

  test "requires subject-bound input" do
    assert {:error, _} = Determinism.bind(%{})
    assert {:error, :refused_invalid_envelope} = Determinism.bind(nil)
  end
end
