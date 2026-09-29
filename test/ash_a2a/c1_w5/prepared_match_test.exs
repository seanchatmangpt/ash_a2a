defmodule AshA2A.C1W5.PreparedMatchTest do
 use ExUnit.Case, async: true
 test "prepared_match" do
  p=Path.join([File.cwd!(),"priv","sa2a","c1","w5_vectors","prepared_match.json"])
  assert File.read!(p)=~"\"sa2a-c1-w5-v1\""
 end
end
