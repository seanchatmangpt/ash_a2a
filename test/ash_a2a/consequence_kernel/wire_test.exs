defmodule AshA2A.WireTest do
 use ExUnit.Case, async: true
 test "wire digest uses canonical identity" do
  assert AshA2A.ConsequenceKernel.Wire.digest(%{"b"=>2,"a"=>1})==AshA2A.ConsequenceKernel.Wire.digest(%{"a"=>1,"b"=>2})
 end
end
