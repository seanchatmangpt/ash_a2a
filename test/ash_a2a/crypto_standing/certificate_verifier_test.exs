defmodule AshA2A.CryptoStanding.CertificateVerifierTest do
  @moduledoc """
  Courts for `AshA2A.C2.CertificateVerifier`: every signature on a certificate is
  verified through `AshA2A.CryptoStanding` (Sa2aCrypto). DB-free, Chicago style: real
  keys, real `:crypto` signatures as the oracle, real registry view, no mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.C2.{Certificate, CertificateVerifier, PreparedEffect}
  alias Sa2aCrypto.{KeyRecord, KeyRef, Registry.Static, SignedMessage}

  @now 1_800_000_000
  @audience "actuator:kernel-1"

  defp effect(payload \\ %{n: 1}),
    do: PreparedEffect.new("principal-1", "cap", "subject", payload)

  defp key(alg \\ "ES256", opts \\ []) do
    {pub, priv} =
      case alg do
        "ES256" -> :crypto.generate_key(:ecdh, :secp256r1)
        "EdDSA" -> :crypto.generate_key(:eddsa, :ed25519)
        "ML-DSA-65" -> :crypto.generate_key(:mldsa65, [])
      end

    kid = KeyRef.kid!(alg, pub)

    rec =
      struct!(
        KeyRecord,
        Keyword.merge(
          [
            kid: kid,
            alg: alg,
            public_key: pub,
            custodian_id: "cust-#{kid}",
            custody_tier: :i2,
            state: :active,
            revocation_epoch: 0
          ],
          opts
        )
      )

    %{alg: alg, kid: kid, priv: priv, rec: rec}
  end

  defp raw_sign("ES256", m, k), do: :crypto.sign(:ecdsa, :sha256, m, [k, :secp256r1])
  defp raw_sign("EdDSA", m, k), do: :crypto.sign(:eddsa, :none, m, [k, :ed25519])
  defp raw_sign("ML-DSA-65", m, k), do: :crypto.sign(:mldsa65, :none, m, k)

  defp fields(e, k, over \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "alg" => k.alg,
        "kid" => k.kid,
        "effect_digest" => e.digest,
        "principal" => e.principal,
        "policy_epoch" => 5,
        "revocation_epoch" => 2,
        "generation" => 9,
        "nonce" => "n-#{k.kid}",
        "not_before" => @now - 10,
        "expires" => @now + 100,
        "audience" => @audience
      },
      over
    )
  end

  # a real signature over the domain-separated message (oracle: :crypto.sign)
  defp sign(e, k, over \\ %{}) do
    {:ok, bytes} = SignedMessage.build(fields(e, k, over))

    %{
      signer: k.kid,
      kid: k.kid,
      alg: k.alg,
      nonce: "n-#{k.kid}",
      signature: raw_sign(k.alg, bytes, k.priv)
    }
  end

  defp cert(e, sigs, over \\ %{}) do
    struct!(
      Certificate,
      Map.merge(
        %{
          effect_digest: e.digest,
          principal: e.principal,
          policy_epoch: 5,
          revocation_epoch: 2,
          generation: 9,
          signatures: sigs,
          v: 1,
          not_before: @now - 10,
          expires: @now + 100,
          audience: @audience
        },
        over
      )
    )
  end

  defp ctx(keys, over \\ %{}) do
    Map.merge(
      %{
        policy_epoch: 5,
        revocation_epoch: 2,
        generation: 9,
        principal: "principal-1",
        registry: Static.view(Enum.map(keys, & &1.rec)),
        audience: @audience,
        now: @now
      },
      over
    )
  end

  describe "garbage signatures (the defect: algorithm-atom-only check)" do
    test "legacy-shaped signature with a supported algorithm atom and garbage bytes is refused" do
      e = effect()
      k = key("EdDSA")
      sig = %{signer: "s1", algorithm: :eddsa, signature: :crypto.strong_rand_bytes(64)}

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(cert(e, [sig]), e, ctx([k]))
    end

    test "registered kid, right alg, random 64 garbage bytes is refused" do
      e = effect()
      k = key("EdDSA")
      sig = %{sign(e, k) | signature: :crypto.strong_rand_bytes(64)}

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(cert(e, [sig]), e, ctx([k]))

      assert {:error, {:certificate_refused, [{:invalid, :bad_signature}]}} =
               CertificateVerifier.standings(cert(e, [sig]), e, ctx([k]))
    end

    test "empty and missing signatures are refused" do
      e = effect()
      k = key()
      assert {:error, :certificate_refused} = CertificateVerifier.verify(cert(e, []), e, ctx([k]))
    end

    test "one valid + one garbage signature is refused (every signature is verified)" do
      e = effect()
      good = key("ES256")
      bad = key("EdDSA")
      sigs = [sign(e, good), %{sign(e, bad) | signature: :crypto.strong_rand_bytes(64)}]

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(cert(e, sigs), e, ctx([good, bad]))
    end
  end

  describe "valid certificates" do
    test "ES256, EdDSA and ML-DSA-65 signatures verify" do
      for alg <- ["ES256", "EdDSA", "ML-DSA-65"] do
        e = effect()
        k = key(alg)
        profile = if alg == "ML-DSA-65", do: :pqc, else: :classical
        c = ctx([k], %{required_profile: profile})
        assert :ok = CertificateVerifier.verify(cert(e, [sign(e, k)]), e, c), alg
      end
    end

    test "two custodians: standings carry custodian, tier, epoch and the (kid, nonce) replay key" do
      e = effect()
      a = key("ES256", custodian_id: "org-a", custody_tier: :i3, revocation_epoch: 4)
      b = key("EdDSA", custodian_id: "org-b", custody_tier: :i4)

      assert {:ok, [x, y]} =
               CertificateVerifier.standings(cert(e, [sign(e, a), sign(e, b)]), e, ctx([a, b]))

      assert {:valid, %{custodian_id: "org-a", tier: :i3, epoch: 4}} = x.standing
      assert {:valid, %{custodian_id: "org-b", tier: :i4}} = y.standing
      assert x.replay_key == {a.kid, "n-#{a.kid}"}
    end

    test "the certificate-level kid/alg/nonce apply when a signature entry omits them" do
      e = effect()
      k = key("EdDSA")
      s = sign(e, k)

      c =
        cert(e, [%{signer: "s", signature: s.signature}], %{
          kid: k.kid,
          alg: k.alg,
          nonce: s.nonce
        })

      assert :ok = CertificateVerifier.verify(c, e, ctx([k]))
    end
  end

  describe "the verifier recomputes from durable state, never the certificate body" do
    test "signature over another effect's digest is refused although the certificate claims this effect" do
      e = effect(%{n: 1})
      other = effect(%{n: 2})
      k = key()
      sig = sign(other, k)

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(cert(e, [sig]), e, ctx([k]))
    end

    test "each signed field, changed after signing, is refused" do
      e = effect()
      k = key()
      good = sign(e, k)
      c = ctx([k])

      mutations = [
        {%{policy_epoch: 6}, %{policy_epoch: 6}},
        {%{revocation_epoch: 3}, %{revocation_epoch: 3}},
        {%{generation: 10}, %{generation: 10}},
        {%{audience: "actuator:other"}, %{}},
        {%{not_before: @now - 11}, %{}},
        {%{expires: @now + 101}, %{}},
        {%{v: 2}, %{}}
      ]

      for {cert_over, ctx_over} <- mutations do
        assert {:error, :certificate_refused} =
                 CertificateVerifier.verify(cert(e, [good], cert_over), e, Map.merge(c, ctx_over)),
               inspect(cert_over)
      end
    end
  end

  describe "context and key standing are enforced" do
    test "no registry in ctx fails closed" do
      e = effect()
      k = key()

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(
                 cert(e, [sign(e, k)]),
                 e,
                 Map.delete(ctx([k]), :registry)
               )
    end

    test "wrong / missing audience, expired, not yet valid" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)])

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(c, e, ctx([k], %{audience: "x"}))

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(c, e, Map.delete(ctx([k]), :audience))

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(c, e, ctx([k], %{now: @now + 100}))

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(c, e, ctx([k], %{now: @now - 11}))

      assert :ok = CertificateVerifier.verify(c, e, ctx([k]))
    end

    test "unknown kid and every non-active key state are refused" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)])
      assert {:error, :certificate_refused} = CertificateVerifier.verify(c, e, ctx([key()]))

      for state <- KeyRecord.states() -- [:active] do
        kk = key("ES256", state: state)

        assert {:error, :certificate_refused} =
                 CertificateVerifier.verify(cert(e, [sign(e, kk)]), e, ctx([kk])),
               "#{state}"
      end
    end

    test "downgrade: a pqc-required context refuses a classical certificate" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)])

      assert {:error, {:certificate_refused, [{:invalid, :profile_downgrade}]}} =
               CertificateVerifier.standings(c, e, ctx([k], %{required_profile: :pqc}))
    end

    test "mediation still runs first (unbound effect is refused before crypto)" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)], %{principal: "someone-else"})
      assert {:error, :refused} = CertificateVerifier.standings(c, e, ctx([k]))
    end
  end

  describe "AshA2A.CryptoStanding adapter" do
    alias AshA2A.CryptoStanding

    test "delegates to Sa2aCrypto: valid standing and typed refusal" do
      e = effect()
      k = key()
      s = sign(e, k)
      {:ok, bytes} = CryptoStanding.signed_message(fields(e, k))

      env = %Sa2aCrypto.Envelope{
        v: 1,
        alg: k.alg,
        kid: k.kid,
        profile: :classical,
        signed_bytes_digest: SignedMessage.digest(bytes),
        signature: s.signature,
        nonce: s.nonce,
        not_before: @now - 10,
        expires: @now + 100,
        audience: @audience
      }

      view = Static.view([k.rec])
      opts = [now: @now, audience: @audience]
      assert {:valid, %{kid: kid}} = CryptoStanding.verify(env, bytes, view, opts)
      assert kid == k.kid

      assert {:invalid, :wrong_audience} =
               CryptoStanding.verify(env, bytes, view, now: @now, audience: "z")
    end
  end

  describe "AshA2A.C2.CryptoVerifier" do
    alias AshA2A.C2.CryptoVerifier

    test "real EdDSA verifies; wrong-size and garbage keys are errors, never raises" do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      sig = :crypto.sign(:eddsa, :none, "m", [priv, :ed25519])
      assert CryptoVerifier.verify(:eddsa, "m", sig, pub) == true
      assert CryptoVerifier.verify(:eddsa, "m!", sig, pub) == {:error, :bad_signature}
      assert CryptoVerifier.verify(:eddsa, "m", sig, <<1, 2>>) == {:error, :bad_key}
      assert CryptoVerifier.verify(:eddsa, "m", sig, nil) == {:error, :bad_key}
    end

    test ":es256 verifies through the same provider; placeholders map to real OTP atoms" do
      {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
      sig = :crypto.sign(:ecdsa, :sha256, "m", [priv, :secp256r1])
      assert CryptoVerifier.verify(:es256, "m", sig, pub) == true
      assert CryptoVerifier.verify(:es256, "m", sig, <<4, 1>>) == {:error, :bad_key}

      {mpub, mpriv} = :crypto.generate_key(:mldsa65, [])
      msig = :crypto.sign(:mldsa65, :none, "m", mpriv)
      assert CryptoVerifier.otp_atom(:ml_dsa) == :mldsa65
      assert CryptoVerifier.otp_atom(:slh_dsa) == :slh_dsa_sha2_128s
      assert CryptoVerifier.verify(:ml_dsa, "m", msig, mpub) == true
      assert CryptoVerifier.verify(:ml_dsa, "m", msig, <<1>>) == {:error, :bad_key}
      assert CryptoVerifier.supported?(:ml_dsa) and CryptoVerifier.supported?(:slh_dsa)
      refute CryptoVerifier.supported?(:rsa)
      assert CryptoVerifier.verify(:rsa, "m", "s", "k") == {:error, :unsupported_algorithm}
    end
  end
end
