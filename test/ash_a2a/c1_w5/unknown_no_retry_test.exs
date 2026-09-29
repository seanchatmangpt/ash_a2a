defmodule AshA2A.C1W5.UnknownNoRetryTest do
  use ExUnit.Case, async: true

  test "unknown_no_retry" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "unknown_no_retry.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
