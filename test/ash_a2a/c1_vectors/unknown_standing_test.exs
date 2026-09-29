defmodule AshA2A.C1UnknownStandingTest do
 use ExUnit.Case, async: true
 test "unknown cannot derive standing" do assert {:error,_}=AshA2A.ConsequenceKernel.Standing.derive(%{outcome: :unknown}) end
end
