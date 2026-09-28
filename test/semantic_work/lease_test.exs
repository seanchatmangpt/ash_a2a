defmodule AshA2A.SemanticWork.LeaseTest do
 use ExUnit.Case, async: true
 alias AshA2A.SemanticWork.Lease
 test "fails closed" do
  assert {:error,_}= Lease.bind(%{})
  assert {:error,:refused_invalid_envelope}= Lease.bind(:invalid)
 end
end
