defmodule AshA2A.C1W5.ReplayExactEffectTest do
  use ExUnit.Case, async: true

  test "replay_exact_effect" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "replay_exact_effect.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
