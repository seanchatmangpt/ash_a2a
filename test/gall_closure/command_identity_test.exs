defmodule AshA2A.GallClosure.CommandIdentityTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.CommandIdentity
 test "bounded admission", do: assert match?({:ok,_}, CommandIdentity.admit(%{command_id: "witness"}))
 test "typed refusal", do: assert CommandIdentity.admit(%{}) == {:error,:missing_command}
end
