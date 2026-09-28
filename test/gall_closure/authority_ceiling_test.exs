defmodule AshA2A.GallClosure.AuthorityCeilingTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.AuthorityCeiling
 test "bounded admission", do: assert match?({:ok,_}, AuthorityCeiling.admit(%{authority: "witness"}))
 test "typed refusal", do: assert AuthorityCeiling.admit(%{}) == {:error,:authority_exceeded}
end
