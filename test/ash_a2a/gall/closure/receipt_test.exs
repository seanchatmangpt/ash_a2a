# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ReceiptTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Receipt

  test "receipt state transitions reseal exact evidence" do
    subject = %{repository: "seanchatmangpt/ash_a2a", sha: String.duplicate("a", 40)}
    finding = %{candidate_digest: "sha256:" <> String.duplicate("b", 64)}
    receipt = Receipt.prepare(subject, finding, %{token_id: "grant-1"}, %{max_consequences: 1})

    assert Receipt.valid?(receipt)
    assert receipt.state == :prepared
    assert receipt.standing == :unknown

    actuated = Receipt.actuated(receipt)
    assert actuated.state == :actuated
    assert Receipt.valid?(actuated)

    verified = Receipt.verified(actuated, %{status: :verified})
    assert verified.state == :completed
    assert verified.standing == :verified
    assert Receipt.valid?(verified)

    replay = Receipt.replay(verified)
    assert replay.replayed?
    assert Receipt.valid?(replay)
  end
end
