defmodule AshA2A.SemanticWork.CompatibilityTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Compatibility

  test "refusal is typed" do
    assert {:error, {:refused_missing_identity, _}} = Compatibility.bind(%{})
  end
end
