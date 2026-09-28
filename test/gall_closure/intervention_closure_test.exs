defmodule AshA2A.GallClosure.InterventionClosureTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.InterventionClosure

  test "bounded admission",
    do: assert(match?({:ok, _}, InterventionClosure.admit(%{closure_id: "witness"})))

  test "typed refusal", do: assert(InterventionClosure.admit(%{}) == {:error, :missing_closure})
end
