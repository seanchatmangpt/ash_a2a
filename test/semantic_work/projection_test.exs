defmodule AshA2A.SemanticWork.ProjectionTest do
 use ExUnit.Case, async: true
 alias AshA2A.SemanticWork.Projection
 test "refusal is typed" do
  assert {:error,{:refused_missing_identity,_}}=Projection.bind(%{})
 end
end
