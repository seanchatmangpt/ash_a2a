defmodule AshA2A.GallClosure.CheckpointBindingTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.CheckpointBinding
 test "bounded admission", do: assert match?({:ok,_}, CheckpointBinding.admit(%{checkpoint: "witness"}))
 test "typed refusal", do: assert CheckpointBinding.admit(%{}) == {:error,:missing_checkpoint}
end
