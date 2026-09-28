defmodule AshA2A.SemanticWork.MigrationTest do
 use ExUnit.Case, async: true
 alias AshA2A.SemanticWork.Migration
 test "refusal is typed" do
  assert {:error,{:refused_missing_identity,_}}=Migration.bind(%{})
 end
end
