# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1CanonicalObjectVectorTest do
  use ExUnit.Case, async: true

  test "map order converges" do
    assert AshA2A.Identity.Canonical.digest(%{"a" => 1, "b" => 2}) ==
             AshA2A.Identity.Canonical.digest(%{"b" => 2, "a" => 1})
  end
end
