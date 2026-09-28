defmodule AshA2A.SemanticWork.CapabilityTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Capability

  test "refusal is typed" do
    assert {:error, {:refused_missing_identity, _}} = Capability.bind(%{})
  end
end
