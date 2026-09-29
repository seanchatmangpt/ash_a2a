defmodule AshA2A.C1W5.SameClaimRefusedTest do
  use ExUnit.Case, async: true

  test "same_claim_refused" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "same_claim_refused.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
