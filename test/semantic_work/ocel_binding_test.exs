defmodule AshA2A.SemanticWork.OcelBindingTest do
 use ExUnit.Case, async: true
 alias AshA2A.SemanticWork.OcelBinding
 test "requires subject-bound input" do
  assert {:error,_}=OcelBinding.bind(%{})
  assert {:error,:refused_invalid_envelope}=OcelBinding.bind(nil)
 end
end
