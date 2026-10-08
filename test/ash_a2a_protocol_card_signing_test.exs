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
      assert_raise ArgumentError, ~r/HS256, RS256 and ES256/, fn ->
        CardSigning.sign(build_card(), @key_a, alg: :HS512)
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

  # -- RS256 / ES256 (asymmetric card signing, TCK CARD-SIGN profile) -------

  describe "RS256 and ES256 sign/verify" do
    test "RS256: sign with RSA private key, verify with public key is :ok" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256, kid: "rsa-1")

      assert {:ok, protected} = protected_header(card)
      assert protected["alg"] == "RS256"
      assert protected["kid"] == "rsa-1"

      assert CardSigning.verify(card, %{"rsa-1" => key}) == :ok
    end

    test "ES256: sign with P-256 private key, verify with public key is :ok" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      card = CardSigning.sign(build_card(), key, alg: :ES256, kid: "ec-1")

      assert {:ok, protected} = protected_header(card)
      assert protected["alg"] == "ES256"

      assert CardSigning.verify(card, %{"ec-1" => key}) == :ok
    end

    test "ES256 signature is the raw 64-byte r||s JWS form, not DER" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      card = CardSigning.sign(build_card(), key, alg: :ES256, kid: "ec-1")

      {:ok, signature} =
        card.signatures |> hd() |> Map.fetch!("signature") |> Base.url_decode64(padding: false)

      assert byte_size(signature) == 64
    end

    test "RS256: wrong public key refuses as bad_signature" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      other = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256, kid: "rsa-1")

      assert {:error, {:bad_signature, %{index: 0}}} =
               CardSigning.verify(card, %{"rsa-1" => other})
    end

    test "ES256: tampered card refuses as digest_mismatch" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      signed = CardSigning.sign(build_card(), key, alg: :ES256, kid: "ec-1")

      tampered = %{signed | description: signed.description <> " TAMPERED"}

      assert {:error, {:digest_mismatch, %{index: 0}}} =
               CardSigning.verify(tampered, %{"ec-1" => key})
    end

    test "PEM round trip: sign with generated key, verify with PEM public key" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

      card = CardSigning.sign(build_card(), pem, alg: :RS256, kid: "pem-1")
      assert CardSigning.verify(card, %{"pem-1" => pem}) == :ok
    end
  end

  describe "JWKS publication and kid rotation" do
    test "JWKS entry matches the signing key; verification via the served JWK is :ok" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256, kid: "rsa-1")

      jwks = CardSigning.jwks([{"rsa-1", key}])
      [jwk] = jwks["keys"]

      assert jwk["kty"] == "RSA"
      assert jwk["kid"] == "rsa-1"
      assert jwk["alg"] == "RS256"
      assert jwk["use"] == "sig"
      refute Map.has_key?(jwk, "d")

      {:RSAPrivateKey, _v, n, e, _d, _p, _q, _dp, _dq, _qi, _other} = key
      assert jwk["n"] == n |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)
      assert jwk["e"] == e |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

      # Verifier resolves the kid through the published JWKS alone.
      assert CardSigning.verify(card, jwks) == :ok
    end

    test "EC JWKS entry carries kty EC / crv P-256 / x / y and verifies" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      card = CardSigning.sign(build_card(), key, alg: :ES256, kid: "ec-1")

      jwks = CardSigning.jwks([{"ec-1", key}])
      [jwk] = jwks["keys"]

      assert %{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} = jwk
      assert byte_size(Base.url_decode64!(x, padding: false)) == 32
      assert byte_size(Base.url_decode64!(y, padding: false)) == 32

      assert CardSigning.verify(card, jwks) == :ok
    end

    test "key rotation: both generations verify while both kids are published" do
      old_key = :public_key.generate_key({:namedCurve, :secp256r1})
      new_key = :public_key.generate_key({:namedCurve, :secp256r1})

      old_card = CardSigning.sign(build_card(), old_key, alg: :ES256, kid: "gen-1")
      new_card = CardSigning.sign(build_card(), new_key, alg: :ES256, kid: "gen-2")

      jwks = CardSigning.jwks([{"gen-1", old_key}, {"gen-2", new_key}])

      assert CardSigning.verify(old_card, jwks) == :ok
      assert CardSigning.verify(new_card, jwks) == :ok
    end

    test "wrong kid in the PROTECTED header refuses as unknown_kid" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256, kid: "rsa-1")

      jwks = CardSigning.jwks([{"other-key", key}])

      assert {:error, {:bad_signature, %{index: 0, reason: :unknown_kid, kid: "rsa-1"}}} =
               CardSigning.verify(card, jwks)
    end

    test "kid selection reads the PROTECTED header only; a rewritten unprotected header never selects a key" do
      # AT5 advisory: `header.kid` is attacker-writable. Forge the unprotected
      # header to point at the TRUSTED kid while the protected header still
      # names the untrusted one; selection must refuse via the protected kid.
      trusted = :public_key.generate_key({:rsa, 2048, 65537})
      untrusted = :public_key.generate_key({:rsa, 2048, 65537})

      card = CardSigning.sign(build_card(), untrusted, alg: :RS256, kid: "untrusted")

      [entry | rest] = card.signatures
      attacker_header = %{"alg" => "RS256", "typ" => "a2a-card", "kid" => "trusted"}
      forged = [%{entry | "header" => attacker_header} | rest]

      jwks = CardSigning.jwks([{"trusted", trusted}])

      # Selection goes through the protected header ("untrusted"), which the
      # published set does not carry: refused, never silently verified with
      # the trusted key despite header.kid == "trusted".
      assert {:error, {:bad_signature, %{reason: :unknown_kid, kid: "untrusted"}}} =
               CardSigning.verify(%{card | signatures: forged}, jwks)
    end

    test "entry without a kid refuses as missing_kid when a rotation set is given" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256)

      assert {:error, {:malformed, %{index: 0, reason: :missing_kid}}} =
               CardSigning.verify(card, CardSigning.jwks([{"k1", key}]))
    end
  end

  defp protected_header(card) do
    card.signatures
    |> hd()
    |> Map.fetch!("protected")
    |> Base.url_decode64(padding: false)
    |> elem(1)
    |> Jason.decode()
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
