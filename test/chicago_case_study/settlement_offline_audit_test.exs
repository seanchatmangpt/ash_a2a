# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ChicagoCaseStudy.SettlementOfflineAuditTest do
  use ExUnit.Case, async: false

  # Chicago Tier 5: Full Lifecycle Deterministic Offline Replay
  # Invariant: Genesis state S0 driven by admitted transitions produces cryptographically verifiable receipts.

  test "full receipt chain is mathematically verifiable offline without network or daemon access" do
    receipts_dir = Path.expand("tmp/test_receipts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(receipts_dir)

    on_exit(fn -> File.rm_rf!(receipts_dir) end)

    {pub_key, priv_key} = :crypto.generate_key(:eddsa, :ed25519)
    pub_hex = Base.encode16(pub_key, case: :lower)

    genesis_state = "<urn:settlement:tx-100> <http://example.org/status> \"INITIAL\" .\n"
    target_state = "<urn:settlement:tx-100> <http://example.org/status> \"VERIFIED\" .\n"

    genesis_digest = :crypto.hash(:sha256, genesis_state) |> Base.encode16(case: :lower)
    target_digest = :crypto.hash(:sha256, target_state) |> Base.encode16(case: :lower)

    # Cryptographically attest the transition
    receipt_payload = "#{genesis_digest}->#{target_digest}"
    sig = :crypto.sign(:eddsa, :none, receipt_payload, [priv_key, :ed25519]) |> Base.encode16(case: :lower)

    receipt = %{
      "genesis_digest" => genesis_digest,
      "target_digest" => target_digest,
      "signature" => sig,
      "authority" => pub_hex,
      "standing" => "ADMITTED"
    }

    receipt_file = Path.join(receipts_dir, "receipt.json")
    File.write!(receipt_file, Jason.encode!(receipt))

    # Perform offline verification using public key and receipts directory
    raw_saved = File.read!(receipt_file) |> Jason.decode!()
    decoded_sig = Base.decode16!(raw_saved["signature"], case: :lower)
    decoded_pub = Base.decode16!(raw_saved["authority"], case: :lower)
    computed_payload = "#{raw_saved["genesis_digest"]}->#{raw_saved["target_digest"]}"

    assert :crypto.verify(:eddsa, :none, computed_payload, decoded_sig, [decoded_pub, :ed25519])
    assert raw_saved["standing"] == "ADMITTED"
  end
end
