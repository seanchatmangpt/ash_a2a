defmodule AshA2A.C1EffectClaimIndependenceTest do
 use ExUnit.Case, async: true
 test "claim API has separate request and effect operations" do assert function_exported?(AshA2A.ConsequenceKernel.Claim,:request,3); assert function_exported?(AshA2A.ConsequenceKernel.Claim,:effect,3) end
end
