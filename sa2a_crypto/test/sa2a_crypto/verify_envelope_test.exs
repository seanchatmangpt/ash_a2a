defmodule Sa2aCrypto.VerifyEnvelopeTest do
  use ExUnit.Case, async: true
  alias Sa2aCrypto.{DER, Envelope, Fixtures, KeyRef, KeyRecord, SignedMessage, Standing}
  alias Sa2aCrypto.Registry.Static
  import Fixtures, only: [opts: 0, opts: 1]

  defp verify(f, o \\ opts()), do: Sa2aCrypto.verify_envelope(f.env, f.bytes, f.view, o)

  defp refused(standing, code), do: assert(standing == {:invalid, code})

  describe "valid standing" do
    for alg <- ["ES256", "EdDSA", "ML-DSA-65", "SLH-DSA-SHA2-128F", "ES256+ML-DSA-65"] do
      test "#{alg}" do
        f = Fixtures.signed(unquote(alg))

        assert {:valid, %{kid: kid, custodian_id: "custodian-1", tier: :i2, epoch: 7}} =
                 verify(f, opts(required_profile: Sa2aCrypto.Suite.profile_of(unquote(alg))))

        assert kid == f.kid

        assert Standing.valid?(
                 verify(f, opts(required_profile: Sa2aCrypto.Suite.profile_of(unquote(alg))))
               )
      end
    end
  end

  describe "negative matrix" do
    test "bit-flip in message (digest not recomputed) is refused" do
      f = Fixtures.signed()
      <<pre::binary-size(60), b, post::binary>> = f.bytes
      bad = <<pre::binary, Bitwise.bxor(b, 1), post::binary>>
      refused(Sa2aCrypto.verify_envelope(f.env, bad, f.view, opts()), :digest_mismatch)
    end

    test "bit-flip in message value with digest recomputed reaches the signature check" do
      f = Fixtures.signed()
      bad = String.replace(f.bytes, "abab", "abac", global: false)
      assert bad != f.bytes
      env = %{f.env | signed_bytes_digest: SignedMessage.digest(bad)}
      refused(Sa2aCrypto.verify_envelope(env, bad, f.view, opts()), :bad_signature)
    end

    test "bit-flip in every signature byte is refused" do
      f = Fixtures.signed()

      for i <- 0..(byte_size(f.sig) - 1) do
        <<pre::binary-size(^i), b, post::binary>> = f.sig
        env = %{f.env | signature: <<pre::binary, Bitwise.bxor(b, 0x80), post::binary>>}
        refused(Sa2aCrypto.verify_envelope(env, f.bytes, f.view, opts()), :bad_signature)
      end
    end

    test "each of the 12 signed fields is bound (ERR7-E-2)" do
      f = Fixtures.signed()

      mutations = %{
        "v" => 2,
        "alg" => "EdDSA",
        "kid" => "other-kid",
        "effect_digest" => "sha256:" <> String.duplicate("cd", 32),
        "principal" => "agent:mallory",
        "policy_epoch" => 4,
        "revocation_epoch" => 8,
        "generation" => 12,
        "nonce" => "nonce-9999",
        "not_before" => f.fields["not_before"] - 1,
        "expires" => f.fields["expires"] + 1,
        "audience" => "actuator:other"
      }

      assert Map.keys(mutations) |> Enum.sort() == Enum.sort(SignedMessage.fields())

      for {field, value} <- mutations do
        {:ok, tampered} = SignedMessage.build(Map.put(f.fields, field, value))
        env = %{f.env | signed_bytes_digest: SignedMessage.digest(tampered)}

        assert {:invalid, code} = Sa2aCrypto.verify_envelope(env, tampered, f.view, opts())
        assert code in [:bad_signature, :message_envelope_mismatch], "#{field}: #{code}"
      end
    end

    test "wrong domain string, even when correctly signed" do
      f = Fixtures.signed()
      <<_::binary-size(20), json::binary>> = f.bytes
      bytes = "SA2A-C2-APPROVAL-v2" <> <<0>> <> json
      sig = Fixtures.raw_sign("ES256", bytes, f.priv)
      env = Fixtures.envelope(f.fields, bytes, sig)
      refused(Sa2aCrypto.verify_envelope(env, bytes, f.view, opts()), :bad_domain)
    end

    test "wrong kid" do
      f = Fixtures.signed()

      refused(
        Sa2aCrypto.verify_envelope(%{f.env | kid: "nope"}, f.bytes, f.view, opts()),
        :unknown_kid
      )

      # registry entry whose kid does not derive from its public key
      {other_pub, _} = Fixtures.keypair("ES256")
      swapped = %{f.key | public_key: other_pub}
      refused(verify(%{f | view: Static.view([swapped])}), :kid_key_mismatch)

      # registered kid, but the signed bytes name another kid
      {:ok, bytes} = SignedMessage.build(Map.put(f.fields, "kid", "someone-else"))
      sig = Fixtures.raw_sign("ES256", bytes, f.priv)
      env = %{f.env | signed_bytes_digest: SignedMessage.digest(bytes), signature: sig}
      refused(Sa2aCrypto.verify_envelope(env, bytes, f.view, opts()), :message_envelope_mismatch)
    end

    test "wrong / downgraded alg" do
      f = Fixtures.signed()
      # envelope and signed bytes both claim EdDSA for an ES256 registry key
      fields = Map.put(f.fields, "alg", "EdDSA")
      {:ok, bytes} = SignedMessage.build(fields)
      env = Fixtures.envelope(fields, bytes, f.sig)
      refused(Sa2aCrypto.verify_envelope(env, bytes, f.view, opts()), :alg_mismatch)
      # envelope alg field alone downgraded, bytes still say ES256
      refused(
        Sa2aCrypto.verify_envelope(
          %{f.env | alg: "EdDSA", profile: :classical},
          f.bytes,
          f.view,
          opts()
        ),
        :alg_mismatch
      )
    end

    test "envelope profile that does not match the alg" do
      f = Fixtures.signed()

      refused(
        Sa2aCrypto.verify_envelope(%{f.env | profile: :pqc}, f.bytes, f.view, opts()),
        :profile_mismatch
      )
    end

    test "expired, not yet valid, wrong and missing audience" do
      f = Fixtures.signed()
      refused(verify(f, opts(now: f.fields["expires"])), :expired)
      refused(verify(f, opts(now: f.fields["expires"] + 1000)), :expired)
      refused(verify(f, opts(now: f.fields["not_before"] - 1)), :not_yet_valid)
      assert {:valid, _} = verify(f, opts(now: f.fields["not_before"]))
      refused(verify(f, opts(audience: "actuator:other")), :wrong_audience)
      refused(verify(f, now: Fixtures.now()), :audience_required)
    end

    test "expires <= not_before is malformed" do
      f = Fixtures.signed("ES256", %{"expires" => Fixtures.now() - 100})
      refused(verify(f), :malformed_envelope)
    end

    test "unsupported and allow-listed-out algorithms" do
      f = Fixtures.signed()

      refused(
        Sa2aCrypto.verify_envelope(%{f.env | alg: "RS256"}, f.bytes, f.view, opts()),
        :unsupported_algorithm
      )

      refused(
        Sa2aCrypto.verify_envelope(%{f.env | alg: "none"}, f.bytes, f.view, opts()),
        :unsupported_algorithm
      )

      refused(verify(f, opts(allowed_algs: ["EdDSA"])), :unsupported_algorithm)
    end

    test "malformed envelopes" do
      f = Fixtures.signed()
      refused(Sa2aCrypto.verify_envelope(%{}, f.bytes, f.view, opts()), :malformed_envelope)
      refused(Sa2aCrypto.verify_envelope(nil, f.bytes, f.view, opts()), :malformed_envelope)

      refused(
        Sa2aCrypto.verify_envelope(%{f.env | signature: 7}, f.bytes, f.view, opts()),
        :bad_signature
      )

      refused(Sa2aCrypto.verify_envelope(f.env, "garbage", f.view, opts()), :digest_mismatch)
      env = %{f.env | signed_bytes_digest: SignedMessage.digest("garbage")}
      refused(Sa2aCrypto.verify_envelope(env, "garbage", f.view, opts()), :bad_domain)
    end

    test "key states other than :active are refused with a typed code" do
      for state <- KeyRecord.states() -- [:active] do
        f = Fixtures.signed("ES256", %{}, state: state)
        refused(verify(f), :"key_#{state}")
      end
    end

    test "key past not_after is refused" do
      f = Fixtures.signed("ES256", %{}, not_after: Fixtures.now() - 1)
      refused(verify(f), :key_expired)
    end

    test "wrong-size and off-curve keys never raise" do
      # registry public key of the wrong size cannot derive its kid
      f = Fixtures.signed()
      short = %{f.key | public_key: binary_part(f.key.public_key, 0, 64)}
      refused(verify(%{f | view: Static.view([short])}), :kid_key_mismatch)

      # 65-byte off-curve point whose kid is honestly derived: Native reports :bad_key
      <<4, x::binary-size(32), y::binary-size(32)>> = f.key.public_key

      off =
        <<4, x::binary, :binary.copy(<<0>>, 31)::binary,
          :binary.last(y) |> Kernel.+(1) |> rem(256)>>

      kid = KeyRef.kid!("ES256", off)
      rec = %{f.key | public_key: off, kid: kid}
      fields = Map.put(f.fields, "kid", kid)
      {:ok, bytes} = SignedMessage.build(fields)
      env = Fixtures.envelope(fields, bytes, f.sig)
      refused(Sa2aCrypto.verify_envelope(env, bytes, Static.view([rec]), opts()), :bad_key)
    end
  end

  describe "malleability and replay keying" do
    test "high-s and low-s twins both stand valid; replay key ignores signature bytes" do
      f = Fixtures.signed()
      {:ok, {r, s}} = DER.parse_ecdsa_sig(f.sig)
      n = DER.n()
      twin_a = DER.encode_ecdsa_sig(r, min(s, n - s))
      twin_b = DER.encode_ecdsa_sig(r, max(s, n - s))
      assert twin_a != twin_b
      ea = %{f.env | signature: twin_a}
      eb = %{f.env | signature: twin_b}
      assert {:valid, _} = Sa2aCrypto.verify_envelope(ea, f.bytes, f.view, opts())
      assert {:valid, _} = Sa2aCrypto.verify_envelope(eb, f.bytes, f.view, opts())
      assert Envelope.replay_key(ea) == Envelope.replay_key(eb)
      assert Envelope.replay_key(ea) == {f.kid, "nonce-0001"}
    end
  end

  describe "profiles (downgrade rules)" do
    test "hybrid and pqc requirements refuse a classical-only envelope" do
      f = Fixtures.signed("ES256")
      refused(verify(f, opts(required_profile: :hybrid)), :profile_downgrade)
      refused(verify(f, opts(required_profile: :pqc)), :profile_downgrade)
      assert {:valid, _} = verify(f, opts(required_profile: :classical))
    end

    test "pqc requirement refuses hybrid; hybrid requirement accepts hybrid and pqc" do
      h = Fixtures.signed("ES256+ML-DSA-65")
      refused(verify(h, opts(required_profile: :pqc)), :profile_downgrade)
      assert {:valid, _} = verify(h, opts(required_profile: :hybrid))
      p = Fixtures.signed("ML-DSA-65")
      assert {:valid, _} = verify(p, opts(required_profile: :hybrid))
      assert {:valid, _} = verify(p, opts(required_profile: :pqc))
    end

    test "stripping a hybrid envelope down to its classical half is refused" do
      h = Fixtures.signed("ES256+ML-DSA-65")
      {cpub, _} = h.key.public_key
      cpriv = elem(h.priv, 0)
      # attacker re-labels as classical with the classical key; the registry key is hybrid
      fields = Map.put(h.fields, "alg", "ES256")
      {:ok, bytes} = SignedMessage.build(fields)
      sig = Fixtures.raw_sign("ES256", bytes, cpriv)
      env = Fixtures.envelope(fields, bytes, sig)
      assert cpub
      refused(Sa2aCrypto.verify_envelope(env, bytes, h.view, opts()), :alg_mismatch)
    end
  end

  describe "provider absent" do
    defmodule NoPqProvider do
      @moduledoc """
      A real, simple provider (not a mock): models a runtime whose OTP lacks the PQ atoms.
      A real absent-atom runtime is not reproducible on OTP 29.1.1, which ships them.
      """
      @behaviour Sa2aCrypto.Provider
      def supports?(alg), do: Sa2aCrypto.Suite.profile_of(alg) == :classical
      def verify(alg, m, s, k), do: Sa2aCrypto.Native.verify(alg, m, s, k)
    end

    test "registered PQ suite with no provider fails closed with :unsupported_suite" do
      f = Fixtures.signed("ML-DSA-65")
      refused(verify(f, opts(provider: NoPqProvider, required_profile: :pqc)), :unsupported_suite)
      g = Fixtures.signed("ES256")
      assert {:valid, _} = verify(g, opts(provider: NoPqProvider))
    end
  end

  describe "wire form" do
    test "envelope JCS round trip" do
      f = Fixtures.signed()
      {:ok, json} = Envelope.encode(f.env)
      assert {:ok, back} = Envelope.decode(json)
      assert back == f.env
      assert {:valid, _} = Sa2aCrypto.verify_envelope(back, f.bytes, f.view, opts())
    end

    test "decode refuses padded, non-canonical, extra-field and non-object input" do
      f = Fixtures.signed()
      {:ok, json} = Envelope.encode(f.env)
      sig64 = Base.url_encode64(f.env.signature, padding: false)

      assert Envelope.decode(String.replace(json, sig64, sig64 <> "=")) ==
               {:error, :malformed_envelope}

      assert Envelope.decode(String.replace(json, "{", ~s({"extra":1,), global: false)) ==
               {:error, :malformed_envelope}

      assert Envelope.decode("[]") == {:error, :malformed_envelope}
      assert Envelope.decode("nope") == {:error, :malformed_envelope}
    end

    test "kid is base64url of 16 bytes of sha256(SPKI DER)" do
      f = Fixtures.signed()
      {:ok, spki} = KeyRef.spki("ES256", f.key.public_key)
      <<h::binary-size(16), _::binary>> = :crypto.hash(:sha256, spki)
      assert f.kid == Base.url_encode64(h, padding: false)
      assert byte_size(Base.url_decode64!(f.kid, padding: false)) == 16
      # SPKI header for P-256 is the standard 26-byte prefix
      assert binary_part(spki, 0, 4) == <<0x30, 0x59, 0x30, 0x13>>
    end
  end
end
