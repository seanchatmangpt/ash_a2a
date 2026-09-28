defmodule AshA2A.GallClosure.StandingGuardTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.StandingGuard
 test "bounded admission", do: assert match?({:ok,_}, StandingGuard.admit(%{standing: "witness"}))
 test "typed refusal", do: assert StandingGuard.admit(%{}) == {:error,:missing_standing}
end
