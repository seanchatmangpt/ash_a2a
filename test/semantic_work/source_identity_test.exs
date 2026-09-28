defmodule AshA2A.SemanticWork.SourceIdentityTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.SourceIdentity

  test "fails closed" do
    assert {:error, _} = SourceIdentity.bind(%{})
    assert {:error, :refused_invalid_envelope} = SourceIdentity.bind(:invalid)
  end
end
