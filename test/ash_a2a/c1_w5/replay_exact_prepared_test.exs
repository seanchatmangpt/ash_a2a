# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W5.ReplayExactPreparedTest do
  use ExUnit.Case, async: true

  test "replay_exact_prepared" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "replay_exact_prepared.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
