# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ReceiptBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.ReceiptBinding

  test "receipt binds command identity, capability, fingerprint and candidate" do
    digest = "sha256:" <> String.duplicate("a", 64)
    candidate = %{candidate_digest: digest}
    command = %{command_id: "c1", capability_id: "Item.create", fingerprint: "fp"}

    receipt = %{
      command_id: "c1",
      capability_id: "Item.create",
      fingerprint: "fp",
      metadata: %{candidate_digest: digest}
    }

    assert {:ok, ^receipt} = ReceiptBinding.admit(receipt, command, candidate)

    assert {:error, {:refused_gall, :receipt_binding, :command_mismatch}} =
             ReceiptBinding.admit(Map.put(receipt, :command_id, "c2"), command, candidate)
  end
end
