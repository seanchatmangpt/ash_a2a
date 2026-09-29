defmodule AshA2A.C1W5.PreparedMismatchTest do
  use ExUnit.Case, async: true

  test "prepared_mismatch" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "prepared_mismatch.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
