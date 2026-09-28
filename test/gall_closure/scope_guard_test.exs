defmodule AshA2A.GallClosure.ScopeGuardTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.ScopeGuard
 test "bounded admission", do: assert match?({:ok,_}, ScopeGuard.admit(%{scope: "witness"}))
 test "typed refusal", do: assert ScopeGuard.admit(%{}) == {:error,:missing_scope}
end
