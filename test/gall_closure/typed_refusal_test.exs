defmodule AshA2A.GallClosure.TypedRefusalTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.TypedRefusal
 test "bounded admission", do: assert match?({:ok,_}, TypedRefusal.admit(%{refusal_code: "witness"}))
 test "typed refusal", do: assert TypedRefusal.admit(%{}) == {:error,:missing_refusal}
end
