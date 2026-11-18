# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.AuditConsumerTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.AuditConsumer

  test "audit consumer carries exact receipt and provenance without authority" do
    receipt = %{
      receipt_id: "r1",
      command_id: "c1",
      terminal_status: :executed,
      standing: :observed
    }

    provenance = %{candidate_digest: "cand", producer_sha: String.duplicate("a", 40)}
    projection = AuditConsumer.project(receipt, provenance)

    assert projection.receipt_id == "r1"
    assert projection.candidate_digest == "cand"
    assert projection.authority == :none
  end
end
