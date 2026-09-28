defmodule AshA2A.GallClosure.CommandBusBoundaryTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.CommandBusBoundary
 test "bounded admission", do: assert match?({:ok,_}, CommandBusBoundary.admit(%{command_bus: "witness"}))
 test "typed refusal", do: assert CommandBusBoundary.admit(%{}) == {:error,:missing_command_bus}
end
