defmodule AshA2A.GallClosure.DeterminismTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.Determinism
  test "bounded admission", do: assert(match?({:ok, _}, Determinism.admit(%{seed: "witness"})))
  test "typed refusal", do: assert(Determinism.admit(%{}) == {:error, :missing_seed})
end
