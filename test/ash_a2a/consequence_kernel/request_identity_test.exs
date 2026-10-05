# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RequestIdentityTest do
  use ExUnit.Case, async: true

  test "request identity is deterministic" do
    assert AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"a" => 1}) ==
             AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"a" => 1})
  end
end
