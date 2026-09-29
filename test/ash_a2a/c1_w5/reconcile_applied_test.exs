defmodule AshA2A.C1W5.ReconcileAppliedTest do
 use ExUnit.Case, async: true
 test "reconcile_applied" do
  p=Path.join([File.cwd!(),"priv","sa2a","c1","w5_vectors","reconcile_applied.json"])
  assert File.read!(p)=~"\"sa2a-c1-w5-v1\""
 end
end
