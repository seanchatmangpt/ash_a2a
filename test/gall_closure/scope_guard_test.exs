defmodule AshA2A.GallClosure.ScopeGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.ScopeGuard

  test "bounded admission", do: assert(match?({:ok, _}, ScopeGuard.admit(%{scope: "repo:a"})))
  test "typed refusal", do: assert(ScopeGuard.admit(%{}) == {:error, :missing_scope})

  test "admits binary, atom, non-empty list and non-empty map scopes" do
    for v <- ["witness", :repo, ["a", "b"], %{repo: "a"}] do
      assert {:ok, %{gall_guard: :scope_guard}} = ScopeGuard.admit(%{scope: v})
    end
  end

  test "refuses wildcard scopes with :scope_escape" do
    for v <- ["*", " * ", "all", "ALL", :all, :*, ["a", "*"]] do
      assert ScopeGuard.admit(%{scope: v}) == {:error, :scope_escape}
    end
  end

  test "refuses empty and malformed scopes with :missing_scope" do
    for v <- ["", "  ", nil, false, true, [], %{}, 5, 1.5] do
      assert ScopeGuard.admit(%{scope: v}) == {:error, :missing_scope}
    end
  end
end
