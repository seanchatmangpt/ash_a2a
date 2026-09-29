defmodule AshA2A.C1W5.IndependentClaimTest do
 use ExUnit.Case, async: true
 test "independent_claim" do
  p=Path.join([File.cwd!(),"priv","sa2a","c1","w5_vectors","independent_claim.json"])
  assert File.read!(p)=~"\"sa2a-c1-w5-v1\""
 end
end
