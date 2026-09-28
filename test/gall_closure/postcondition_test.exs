defmodule AshA2A.GallClosure.PostconditionTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.Postcondition

  test "bounded admission",
    do: assert(match?({:ok, _}, Postcondition.admit(%{postcondition: "witness"})))

  test "typed refusal", do: assert(Postcondition.admit(%{}) == {:error, :missing_postcondition})
end
