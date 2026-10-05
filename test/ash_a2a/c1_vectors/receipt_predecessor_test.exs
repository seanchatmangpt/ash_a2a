# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1ReceiptPredecessorTest do
  use ExUnit.Case, async: true

  test "predecessor changes digest" do
    assert AshA2A.ConsequenceKernel.ReceiptChain.next("a", %{"r" => 1}) !=
             AshA2A.ConsequenceKernel.ReceiptChain.next("b", %{"r" => 1})
  end
end
