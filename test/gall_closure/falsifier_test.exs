defmodule AshA2A.GallClosure.FalsifierTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.Falsifier
 test "bounded admission", do: assert match?({:ok,_}, Falsifier.admit(%{falsifier: "witness"}))
 test "typed refusal", do: assert Falsifier.admit(%{}) == {:error,:missing_falsifier}
end
