defmodule AshA2A.GallClosure.ObservationGuardTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.ObservationGuard
 test "bounded admission", do: assert match?({:ok,_}, ObservationGuard.admit(%{observation_id: "witness"}))
 test "typed refusal", do: assert ObservationGuard.admit(%{}) == {:error,:missing_observation}
end
