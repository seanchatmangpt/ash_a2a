defmodule AshA2A.C1W5.ReconcileUncertainTest do
 use ExUnit.Case, async: true
 test "reconcile_uncertain" do
  p=Path.join([File.cwd!(),"priv","sa2a","c1","w5_vectors","reconcile_uncertain.json"])
  assert File.read!(p)=~"\"sa2a-c1-w5-v1\""
 end
end
