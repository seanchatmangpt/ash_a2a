defmodule AshA2A.SemanticWork.ProviderTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Provider

  test "refusal is typed" do
    assert {:error, {:refused_missing_identity, _}} = Provider.bind(%{})
  end
end
