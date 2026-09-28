defmodule AshA2A.GallClosure.OcelIdentityTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.OcelIdentity
 test "bounded admission", do: assert match?({:ok,_}, OcelIdentity.admit(%{ocel_event_id: "witness"}))
 test "typed refusal", do: assert OcelIdentity.admit(%{}) == {:error,:missing_ocel_event}
end
