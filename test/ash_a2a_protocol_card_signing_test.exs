defmodule AshA2A.Test.CardSigningFixture do
  @moduledoc """
  Real ETS-backed `Ash.Resource` fixture for
  `test/ash_a2a_protocol_card_signing_test.exs` (lane V18) — a genuine
  `Ash.Resource` with `extensions: [AshA2A]` and one real `a2a do skill ...
  end` declaration, plus its `Ash.Domain`, so `AshA2A.Info.agent_card/2`
  builds the card from the same compiled capability index the runtime
  serves. Defined inside the test file itself (owned-file constraint);
  no mocks anywhere.
  """

  use Ash.Resource,
    domain: AshA2A.Test.CardSigningFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:utterance, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.Test.CardSigningFixture.Domain do
  @moduledoc """
  Real fixture domain pairing `AshA2A.Test.CardSigningFixture` so
  `AshA2A.Info.agent_card/2` has a real, verified capability index to build
  the card from.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.CardSigningFixture)
  end
end

defmodule AshA2A.Protocol.CardSigningTest do
  @moduledoc """
  Real round-trip court for `AshA2A.Protocol.CardSigning` (lane V18, wire
  stability re-cut by lane Y7): a real ETS-backed `Ash.Resource` fixture
  defined in this file, a real card built through `AshA2A.Info.agent_card/2`,
  real HMAC-SHA256 JWS signing and verification over the vendored RFC 8785
  canonicalizer (`Jcs.encode/1`). Signatures are computed over the v1.0
  WIRE-PROJECTED card (the codec-canonical form via
  `AshA2A.Protocol.JSON.encode_agent_card/2` + a Jason round trip), so they
  survive the exact encode/decode round trip a wire peer performs. Zero mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.CardSigning

  @resource AshA2A.Test.CardSigningFixture
  @key_a :crypto.strong_rand_bytes(32)
  @key_b :crypto.strong_rand_bytes(32)

  describe "sign/3 + verify/3 real round trip" do
    test "sign with key A, verify with key A is :ok" do
      signed = signed_card()

      assert [%{"protected" => _, "header" => _, "signature" => _}] = signed.signatures
      assert CardSigning.verify(signed, @key_a) == :ok
    end

    test "verify with the wrong key is {:error, {:bad_signature, %{index: 0}}}" do
      signed = signed_card()

      assert {:error, {:bad_signature, %{index: 0}}} = CardSigning.verify(signed, @key_b)
    end

    test "tampering a skill description after signing is {:error, {:digest_mismatch, ...}}" do
      signed = signed_card()
      [skill] = signed.skills

      tampered = %{signed | skills: [%{skill | description: "TAMPERED after signing"}]}

      assert {:error, {:digest_mismatch, %{index: 0, actual: _, expected: _}}} =
               CardSigning.verify(tampered, @key_a)
    end

    test "signing twice appends a second entry and both verify" do
      signed_twice = signed_card() |> CardSigning.sign(@key_a)

      assert length(signed_twice.signatures) == 2
      assert CardSigning.verify(signed_twice, @key_a) == :ok

      # Wrong key fails on the FIRST entry (index 0).
      assert {:error, {:bad_signature, %{index: 0}}} =
               CardSigning.verify(signed_twice, @key_b)
    end

    test "protected header is exactly {alg HS256, typ a2a-card, sha256 digest of wire-projected card minus signatures}" do
      signed = signed_card()
      [entry] = signed.signatures

      assert {:ok, protected_json} = Base.url_decode64(entry["protected"], padding: false)
      assert {:ok, protected} = Jason.decode(protected_json)

      assert %{"alg" => "HS256", "typ" => "a2a-card"} = protected
      assert is_binary(protected["sha256"]) and byte_size(protected["sha256"]) == 64

      # Independently recomputed: JCS of the wire-projected card (the exact
      # codec-canonical document a peer sees) minus signatures.
      expected_digest = wire_digest(signed)

      assert protected["sha256"] == expected_digest
    end

    test "in-memory-only fields (top-level protocol_version) do not change the digest" do
      # v1.0 wire has NO top-level protocolVersion (json.ex never emits one;
      # V10/V11 courts pin its absence), so flipping the in-memory
      # protocol_version must not move the digest.
      with_version = %{signed_card() | protocol_version: "1.0"}
      without_version = %{signed_card() | protocol_version: nil}

      [a] = with_version.signatures
      [b] = without_version.signatures
      assert a["protected"] == b["protected"]
    end

    test "signature verifies against the standard RFC 7797 detached signing input over the wire projection" do
      signed = signed_card()
      [entry] = signed.signatures

      {:ok, signature} = Base.url_decode64(entry["signature"], padding: false)

      payload = wire_payload(signed)

      # Signing input = b64url(protected) <> "." <> detached JCS payload.
      signing_input = <<entry["protected"]::binary, ?., payload::binary>>

      assert signature == :crypto.mac(:hmac, :sha256, @key_a, signing_input)
    end

    test "sign -> encode_agent_card -> Jason -> decode_agent_card -> verify :ok" do
      # protocol_version "1.0" exists only in memory: the v1.0 wire carries
      # protocolVersion only inside supportedInterfaces[] (json.ex emits no
      # top-level member), so this card proves the fix — signatures computed
      # over the CODEC-CANONICAL form survive the exact round trip a wire
      # peer performs.
      signed = %{signed_card() | protocol_version: "1.0"}
      assert signed.protocol_version == "1.0"

      wire = AshA2A.Protocol.JSON.encode_agent_card(signed, url: signed.url)
      refute Map.has_key?(wire, "protocolVersion")
      assert is_list(wire["signatures"]) and length(wire["signatures"]) == 1

      assert {:ok, decoded} =
               wire
               |> Jason.encode!()
               |> Jason.decode!()
               |> AshA2A.Protocol.JSON.decode_agent_card()

      assert decoded.signatures == signed.signatures
      # In-memory protocol_version is nil post-decode; verification still
      # passes because the digest never covered it.
      assert decoded.protocol_version != signed.protocol_version
      assert CardSigning.verify(decoded, @key_a) == :ok
    end

    test "an unsigned card is refused as {:error, {:malformed, :no_signatures}}" do
      assert {:error, {:malformed, :no_signatures}} = CardSigning.verify(build_card(), @key_a)
    end

    test "unsupported :alg raises on sign; forged HS512 entry is refused as malformed" do
      assert_raise ArgumentError, ~r/HS256/, fn ->
        CardSigning.sign(build_card(), @key_a, alg: :ES256)
      end

      forged = %{
        signed_card()
        | signatures: [
            %{
              "protected" =>
                Base.url_encode64(
                  Jason.encode!(%{"alg" => "HS512", "typ" => "a2a-card", "sha256" => "0"}),
                  padding: false
                ),
              "header" => %{"alg" => "HS512", "typ" => "a2a-card"},
              "signature" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
            }
          ]
      }

      assert {:error, {:malformed, %{index: 0, reason: :unsupported_alg}}} =
               CardSigning.verify(forged, @key_a)
    end
  end

  defp build_card do
    AshA2A.Info.agent_card(@resource, name: "card_signing_fixture_agent")
  end

  defp signed_card do
    CardSigning.sign(build_card(), @key_a)
  end

  # The codec-canonical card document minus signatures, as JCS bytes — the
  # exact payload CardSigning digests (moduledoc: signatures are computed
  # over the v1.0 WIRE-PROJECTED card, cite lib/ash_a2a/protocol/json.ex).
  defp wire_payload(card) do
    card
    |> AshA2A.Protocol.JSON.encode_agent_card(url: card.url)
    |> Map.delete("signatures")
    |> Jason.encode!()
    |> Jason.decode!()
    |> Jcs.encode()
  end

  defp wire_digest(card) do
    wire_payload(card)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
