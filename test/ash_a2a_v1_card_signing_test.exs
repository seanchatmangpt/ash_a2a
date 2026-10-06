# A2A v1.0 spec section 8.4 — agent-card signing courts (CARD-SIGN-001..004).
#
# The official TCK tags CARD-SIGN-* NOT_AUTOMATABLE (no executable TCK test
# exists for them); this court is the exercised surface for those four
# requirements against the real `AshA2A.Protocol.CardSigning` machinery over
# real canonicalization, real HMAC and real verification — no mocks.
#
#   CARD-SIGN-001 (JCS/RFC 8785): a signature made over the JCS bytes of the
#     card still verifies when the same card document arrives with a
#     different member order — canonically identical documents share a
#     digest; a tampered VALUE is refused (:digest_mismatch).
#   CARD-SIGN-002 (signatures excluded from signed content): re-signing grows
#     `signatures` without invalidating earlier entries (the digest is
#     computed over the card MINUS `signatures`), and mutating any other
#     member IS caught.
#   CARD-SIGN-003 (protected header MUST include alg + kid): asserted on the
#     real header bytes of a `kid:`-signed card.
#   CARD-SIGN-004 (expired/revoked keys must not verify): a key that has been
#     rotated away (no longer the published key) refuses :bad_signature.
#
# CARD-EXT-001/002 are exercised end-to-end by the official TCK against
# tck_sut.exs (signed public card with `extendedAgentCard` capability +
# extended card endpoint with explicit private cache headers).

defmodule AshA2A.V1CardSigningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{AgentCard, CardSigning, JSON}

  defp base_card do
    %AgentCard{
      name: "card-signing-court",
      description: "CARD-SIGN-001..004 exercised court",
      url: "http://127.0.0.1:1",
      version: "1.0.0",
      skills: [
        %{
          id: "echo",
          name: "Echo",
          description: "echo skill",
          tags: ["tck"]
        }
      ]
    }
  end

  defp b64url_decode(bin), do: Base.url_decode64!(bin, padding: false)
  defp b64url_encode(bin), do: Base.url_encode64(bin, padding: false)

  # -- CARD-SIGN-001 (JCS / RFC 8785 canonicalization) ---------------------

  describe "CARD-SIGN-001 JCS canonicalization" do
    test "signature survives member-order change of the same document" do
      card = base_card()
      key = :crypto.strong_rand_bytes(32)
      signed = CardSigning.sign(card, key, kid: "court-key-1")

      wire = JSON.encode_agent_card(signed, url: "http://127.0.0.1:1")

      # Same document, different serialization: members reversed.
      reserialized = wire |> Enum.reverse() |> Map.new() |> Jason.encode!()

      canon = fn bytes ->
        bytes |> Jason.decode!() |> Map.delete("signatures") |> Jcs.encode()
      end

      # Canonically identical documents share the digest the JWS binds.
      expected_digest =
        :crypto.hash(:sha256, canon.(reserialized)) |> Base.encode16(case: :lower)

      protected =
        signed.signatures |> hd() |> Map.fetch!("protected") |> b64url_decode() |> Jason.decode!()

      assert protected["sha256"] == expected_digest

      # The MAC covers protected_b64 <> "." <> JCS(reserialization).
      protected_b64 = signed.signatures |> hd() |> Map.fetch!("protected")
      expected_mac = :crypto.mac(:hmac, :sha256, key, protected_b64 <> "." <> canon.(reserialized))

      assert :crypto.hash_equals(expected_mac, signed.signatures |> hd() |> Map.fetch!("signature") |> b64url_decode())

      # And the real verifier accepts the canonically identical document
      # (codec round trip: encode -> decode -> verify, wire-stable).
      assert {:ok, round_tripped} = JSON.decode_agent_card(wire)
      assert CardSigning.verify(round_tripped, key, url: "http://127.0.0.1:1") == :ok
    end

    test "tampered card VALUE is refused as digest_mismatch" do
      card = base_card()
      key = :crypto.strong_rand_bytes(32)
      signed = CardSigning.sign(card, key, kid: "court-key-1")

      tampered =
        signed
        |> Map.update!(:description, &(&1 <> " TAMPERED"))

      assert {:error, {:digest_mismatch, %{index: 0}}} =
               CardSigning.verify(tampered, key, url: "http://127.0.0.1:1")
    end
  end

  # -- CARD-SIGN-002 (signatures excluded from signed content) -------------

  describe "CARD-SIGN-002 signatures excluded from signed content" do
    test "re-signing preserves earlier signatures (digest ignores signatures)" do
      card = base_card()
      key = :crypto.strong_rand_bytes(32)

      signed1 = CardSigning.sign(card, key, kid: "court-key-1")
      assert length(signed1.signatures) == 1

      signed2 = CardSigning.sign(signed1, key, kid: "court-key-2")
      assert length(signed2.signatures) == 2

      # Both entries still verify: the second signature's digest was computed
      # over the card minus ALL signatures, so the first entry is untouched.
      assert CardSigning.verify(signed2, key, url: "http://127.0.0.1:1") == :ok
    end

    test "mutating a non-signatures member IS caught" do
      card = base_card()
      key = :crypto.strong_rand_bytes(32)
      signed = CardSigning.sign(card, key)

      tampered = %{signed | description: signed.description <> " TAMPERED"}

      assert {:error, {:digest_mismatch, %{index: 0}}} =
               CardSigning.verify(tampered, key, url: "http://127.0.0.1:1")
    end
  end

  # -- CARD-SIGN-003 (protected header carries alg + kid) ------------------

  describe "CARD-SIGN-003 protected header alg + kid" do
    test "kid-signed card carries alg and kid in the protected header" do
      card = base_card()
      key = :crypto.strong_rand_bytes(32)

      signed = CardSigning.sign(card, key, kid: "court-key-1")
      entry = hd(signed.signatures)

      protected = entry |> Map.fetch!("protected") |> b64url_decode() |> Jason.decode!()

      assert protected["alg"] == "HS256"
      assert protected["kid"] == "court-key-1"
      # The unprotected header mirrors the protected parameters.
      assert entry["header"]["alg"] == "HS256"
      assert entry["header"]["kid"] == "court-key-1"
    end

    test "verify refuses a non-HS256 alg claim" do
      card = base_card()
      key = :crypto.strong_rand_bytes(32)
      signed = CardSigning.sign(card, key, kid: "k1")

      forged =
        update_in(signed.signatures, fn [entry | rest] ->
          protected = entry |> Map.fetch!("protected") |> b64url_decode() |> Jason.decode!()

          # RS256/ES256 are now first-class (lane G4), so the alg-claim
          # tamper court forges an alg that is NOT supported at all.
          forged_protected = b64url_encode(Jason.encode!(%{protected | "alg" => "HS512"}))

          [%{entry | "protected" => forged_protected} | rest]
        end)

      assert {:error, {:malformed, %{reason: :unsupported_alg}}} =
               CardSigning.verify(forged, key)
    end

    test "verify refuses an alg claim the verifier holds no key for" do
      # An HS256 secret cannot satisfy an RS256/ES256 claim: forging the
      # protected alg to a supported-but-wrong-family algorithm must still
      # refuse (key type mismatch), never verify and never raise.
      card = base_card()
      key = :crypto.strong_rand_bytes(32)
      signed = CardSigning.sign(card, key, kid: "k1")

      forged =
        update_in(signed.signatures, fn [entry | rest] ->
          protected = entry |> Map.fetch!("protected") |> b64url_decode() |> Jason.decode!()
          forged_protected = b64url_encode(Jason.encode!(%{protected | "alg" => "ES256"}))
          [%{entry | "protected" => forged_protected} | rest]
        end)

      assert {:error, {:malformed, %{reason: :key_type_mismatch, alg: "ES256"}}} =
               CardSigning.verify(forged, key)
    end
  end

  # -- CARD-SIGN-004 (expired/revoked keys must not verify) ----------------

  describe "CARD-SIGN-004 revoked/rotated keys refuse verification" do
    test "a rotated-away key refuses with bad_signature" do
      card = base_card()
      signing_key = :crypto.strong_rand_bytes(32)
      signed = CardSigning.sign(card, signing_key, kid: "court-key-1")

      # The verifier's key store now holds ONLY the successor key.
      assert {:error, {:bad_signature, %{index: 0}}} =
               CardSigning.verify(signed, :crypto.strong_rand_bytes(32))
    end
  end
end
