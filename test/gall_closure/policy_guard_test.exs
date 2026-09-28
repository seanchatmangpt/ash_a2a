defmodule AshA2A.GallClosure.PolicyGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.PolicyGuard

  test "bounded admission",
    do: assert(match?({:ok, _}, PolicyGuard.admit(%{policy_id: "witness"})))

  test "typed refusal", do: assert(PolicyGuard.admit(%{}) == {:error, :missing_policy})
end
