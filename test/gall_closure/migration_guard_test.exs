defmodule AshA2A.GallClosure.MigrationGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.MigrationGuard

  test "bounded admission",
    do: assert(match?({:ok, _}, MigrationGuard.admit(%{representation_version: "witness"})))

  test "typed refusal", do: assert(MigrationGuard.admit(%{}) == {:error, :missing_version})
end
