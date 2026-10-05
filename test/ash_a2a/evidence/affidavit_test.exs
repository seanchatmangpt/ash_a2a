# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Evidence.AffidavitTest do
  use ExUnit.Case, async: true

  alias AshA2A.Evidence.Affidavit

  setup do
    if Affidavit.available?() and is_nil(Process.whereis(AshAffidavit.Pool)) do
      start_supervised!({AshAffidavit.Pool, size: 2})
    end
    :ok
  end

  describe "AshA2A.Evidence.Affidavit" do
    test "available?/0 returns true when ash_affidavit is loaded" do
      assert Affidavit.available?() == true
    end

    test "assemble_receipt/1 and verify_receipt/1 execute with real WASM engine" do
      events = [
        %{"event_type" => "start", "objects" => ["task:1"], "payload" => "init"},
        %{"event_type" => "finish", "objects" => ["task:1"], "payload" => "done"}
      ]

      assert {:ok, assembled} = Affidavit.assemble_receipt(events)
      assert is_map(assembled)
      assert Map.has_key?(assembled, "receipt")

      assert {:ok, true} = Affidavit.verify_receipt(assembled["receipt"])
    end
  end
end
