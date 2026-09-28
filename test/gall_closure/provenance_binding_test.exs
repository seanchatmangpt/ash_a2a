defmodule AshA2A.GallClosure.ProvenanceBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.ProvenanceBinding

  test "bounded admission",
    do: assert(match?({:ok, _}, ProvenanceBinding.admit(%{source_sha: "witness"})))

  test "typed refusal", do: assert(ProvenanceBinding.admit(%{}) == {:error, :missing_source_sha})
end
