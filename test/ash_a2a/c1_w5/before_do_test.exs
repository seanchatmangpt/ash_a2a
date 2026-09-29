defmodule AshA2A.C1W5.BeforeDoTest do
  use ExUnit.Case, async: true

  test "before_do" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "before_do.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
