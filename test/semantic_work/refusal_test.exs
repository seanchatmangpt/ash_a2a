defmodule AshA2A.SemanticWork.RefusalTest do
 use ExUnit.Case, async: true
 alias AshA2A.SemanticWork.Refusal
 test "refusal is typed" do
  assert {:error,{:refused_missing_identity,_}}=Refusal.bind(%{})
 end
end
