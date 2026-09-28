defmodule AshA2A.SemanticWork.ScopeTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Scope

  test "refusal is typed" do
    assert {:error, {:refused_missing_identity, _}} = Scope.bind(%{})
  end
end
