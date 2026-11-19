# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.Court.C017Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 17 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-17", "capability", "subject", %{court: 17})
    b = AshA2A.C2.PreparedEffect.new("principal-17", "capability", "subject", %{court: 18})
    refute a.digest == b.digest
  end
end
