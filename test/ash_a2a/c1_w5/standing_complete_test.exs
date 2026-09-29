defmodule AshA2A.C1W5.StandingCompleteTest do
 use ExUnit.Case, async: true
 test "standing_complete" do
  p=Path.join([File.cwd!(),"priv","sa2a","c1","w5_vectors","standing_complete.json"])
  assert File.read!(p)=~"\"sa2a-c1-w5-v1\""
 end
end
