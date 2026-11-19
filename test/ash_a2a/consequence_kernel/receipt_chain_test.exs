# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReceiptChainTest do
  use ExUnit.Case, async: true

  test "chain digest binds predecessor" do
    assert AshA2A.ConsequenceKernel.ReceiptChain.next("a", %{"x" => 1}) !=
             AshA2A.ConsequenceKernel.ReceiptChain.next("b", %{"x" => 1})
  end
end
