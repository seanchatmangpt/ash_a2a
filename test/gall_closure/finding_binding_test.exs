defmodule AshA2A.GallClosure.FindingBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.FindingBinding

  test "bounded admission",
    do: assert(match?({:ok, _}, FindingBinding.admit(%{finding_id: "witness"})))

  test "typed refusal", do: assert(FindingBinding.admit(%{}) == {:error, :missing_finding})
end
