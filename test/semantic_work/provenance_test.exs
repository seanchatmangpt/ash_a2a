defmodule AshA2A.SemanticWork.ProvenanceTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Provenance

  test "fails closed" do
    assert {:error, _} = Provenance.bind(%{})
    assert {:error, :refused_invalid_envelope} = Provenance.bind(:invalid)
  end
end
