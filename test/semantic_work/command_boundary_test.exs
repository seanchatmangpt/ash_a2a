defmodule AshA2A.SemanticWork.CommandBoundaryTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.CommandBoundary

  test "requires subject-bound input" do
    assert {:error, _} = CommandBoundary.bind(%{})
    assert {:error, :refused_invalid_envelope} = CommandBoundary.bind(nil)
  end
end
