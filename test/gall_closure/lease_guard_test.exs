defmodule AshA2A.GallClosure.LeaseGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.LeaseGuard

  test "bounded admission",
    do: assert(match?({:ok, _}, LeaseGuard.admit(%{lease_epoch: "witness"})))

  test "typed refusal", do: assert(LeaseGuard.admit(%{}) == {:error, :missing_lease})
end
