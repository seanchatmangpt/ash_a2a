defmodule AshA2A.SemanticWork.CheckpointTest do
 use ExUnit.Case, async: true
 alias AshA2A.SemanticWork.Checkpoint
 test "fails closed" do
  assert {:error,_}= Checkpoint.bind(%{})
  assert {:error,:refused_invalid_envelope}= Checkpoint.bind(:invalid)
 end
end
