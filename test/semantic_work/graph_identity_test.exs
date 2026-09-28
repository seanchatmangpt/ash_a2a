defmodule AshA2A.SemanticWork.GraphIdentityTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.GraphIdentity

  test "fails closed" do
    assert {:error, _} = GraphIdentity.bind(%{})
    assert {:error, :refused_invalid_envelope} = GraphIdentity.bind(:invalid)
  end
end
