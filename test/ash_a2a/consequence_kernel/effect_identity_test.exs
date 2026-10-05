# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EffectIdentityTest do
  use ExUnit.Case, async: true

  test "effect identity binds request" do
    assert AshA2A.ConsequenceKernel.EffectIdentity.derive("r1", %{"x" => 1}) !=
             AshA2A.ConsequenceKernel.EffectIdentity.derive("r2", %{"x" => 1})
  end
end
