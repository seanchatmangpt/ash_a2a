defmodule AshA2A.C1W5.ClaimIdentityInvalidTest do
  use ExUnit.Case, async: true

  test "claim_identity_invalid" do
    p =
      Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "claim_identity_invalid.json"])

    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
