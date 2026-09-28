defmodule AshA2A.SemanticWork.PostconditionTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Postcondition

  test "requires subject-bound input" do
    assert {:error, _} = Postcondition.bind(%{})
    assert {:error, :refused_invalid_envelope} = Postcondition.bind(nil)
  end
end
