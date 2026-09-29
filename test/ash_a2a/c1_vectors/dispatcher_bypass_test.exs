defmodule AshA2A.C1DispatcherBypassTest do
 use ExUnit.Case, async: true
 test "legacy direct dispatch refused" do assert {:error,:kernel_bypass}=AshA2A.ConsequenceKernel.CompleteMediation.admit_call_path([AshA2A.Dispatcher]) end
end
