defmodule AshA2A.SemanticWork.AuthorityCeilingTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.AuthorityCeiling

  test "fails closed" do
    assert {:error, _} = AuthorityCeiling.bind(%{})
    assert {:error, :refused_invalid_envelope} = AuthorityCeiling.bind(:invalid)
  end
end
