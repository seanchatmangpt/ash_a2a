defmodule AshA2A.GallClosure.RecoveryRouteTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.RecoveryRoute

  test "bounded admission",
    do: assert(match?({:ok, _}, RecoveryRoute.admit(%{recovery: "witness"})))

  test "typed refusal", do: assert(RecoveryRoute.admit(%{}) == {:error, :missing_recovery})
end
