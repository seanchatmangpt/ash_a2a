defmodule AshA2A.RefusalRegistryTest do
 use ExUnit.Case, async: true
 test "kernel refusals are typed" do
  for c <- AshA2A.ConsequenceKernel.RefusalRegistry.codes(), do: assert AshA2A.ConsequenceKernel.RefusalRegistry.known?(c)
 end
end
