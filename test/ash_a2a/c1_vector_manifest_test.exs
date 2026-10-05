# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1VectorManifestTest do
  use ExUnit.Case, async: true

  test "portable vector corpus exists" do
    files = Path.wildcard("priv/sa2a/c1/vectors/*.json")
    assert length(files) >= 18
    for f <- files, do: assert({:ok, _} = Jason.decode(File.read!(f)))
  end
end
