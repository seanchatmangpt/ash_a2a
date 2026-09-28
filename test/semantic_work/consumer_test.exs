defmodule AshA2A.SemanticWork.ConsumerTest do
 use ExUnit.Case, async: true
 alias AshA2A.SemanticWork.Consumer
 test "refusal is typed" do
  assert {:error,{:refused_missing_identity,_}}=Consumer.bind(%{})
 end
end
