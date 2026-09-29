defmodule AshA2A.C1W5.ClaimIdentityTest do
 use ExUnit.Case, async: true
 test "claim_identity" do
  p=Path.join([File.cwd!(),"priv","sa2a","c1","w5_vectors","claim_identity.json"])
  assert File.read!(p)=~"\"sa2a-c1-w5-v1\""
 end
end
