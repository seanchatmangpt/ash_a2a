defmodule AshA2A.GallClosure.MigrationGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.MigrationGuard

  test "bounded admission",
    do: assert(match?({:ok, _}, MigrationGuard.admit(%{representation_version: "v1"})))

  test "typed refusal", do: assert(MigrationGuard.admit(%{}) == {:error, :missing_version})

  test "admits non-empty binary and positive integer versions" do
    assert {:ok, %{gall_guard: :migration_guard}} =
             MigrationGuard.admit(%{representation_version: "2024-01"})

    assert {:ok, _} = MigrationGuard.admit(%{representation_version: 3})
  end

  test "refuses empty, blank, zero, negative, and other types" do
    for v <- ["", "  ", 0, -1, 1.0, :v1, true, nil, false, [], %{}] do
      assert MigrationGuard.admit(%{representation_version: v}) == {:error, :missing_version}
    end
  end
end
