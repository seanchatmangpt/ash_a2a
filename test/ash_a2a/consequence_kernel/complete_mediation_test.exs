defmodule AshA2A.CompleteMediationTest do
 use ExUnit.Case, async: true
 test "direct dispatcher is a kernel bypass" do
  assert {:error,:kernel_bypass}=AshA2A.ConsequenceKernel.CompleteMediation.admit_call_path([AshA2A.Dispatcher])
 end
end
