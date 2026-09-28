defmodule AshA2A.GallClosure.CompatibilityGuardTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.CompatibilityGuard
 test "bounded admission", do: assert match?({:ok,_}, CompatibilityGuard.admit(%{compatibility: "witness"}))
 test "typed refusal", do: assert CompatibilityGuard.admit(%{}) == {:error,:missing_compatibility}
end
