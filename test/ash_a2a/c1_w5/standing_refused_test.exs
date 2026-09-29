defmodule AshA2A.C1W5.StandingRefusedTest do
 use ExUnit.Case, async: true
 test "standing_refused" do
  p=Path.join([File.cwd!(),"priv","sa2a","c1","w5_vectors","standing_refused.json"])
  assert File.read!(p)=~"\"sa2a-c1-w5-v1\""
 end
end
