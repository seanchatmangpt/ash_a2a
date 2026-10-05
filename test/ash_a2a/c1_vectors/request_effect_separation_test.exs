# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1RequestEffectSeparationTest do
  use ExUnit.Case, async: true

  test "request and effect domains differ" do
    assert AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"x" => 1}) !=
             AshA2A.ConsequenceKernel.EffectIdentity.derive("r", %{"x" => 1})
  end
end
