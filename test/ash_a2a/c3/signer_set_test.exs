defmodule AshA2A.C3.SignerSetTest do
  # DB-free: real Ed25519 keys and signatures (:crypto), real Sa2aCrypto registry and
  # verifier; no Repo, no Oban.
  use ExUnit.Case, async: true
  alias AshA2A.C3.SignerSet
  alias Sa2aCrypto.{Envelope, KeyRecord, KeyRef, SignedMessage}
  alias Sa2aCrypto.Registry.Static

  @aud "actuator:c3-test"
  @now 1_800_000_000

  defp key(custodian, tier \\ :i2) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    kid = KeyRef.kid!("EdDSA", pub)

    %{
      priv: priv,
      kid: kid,
      record: %KeyRecord{
        kid: kid,
        alg: "EdDSA",
        public_key: pub,
        custodian_id: custodian,
        custody_tier: tier,
        state: :active,
        revocation_epoch: 0
      }
    }
  end

  defp approve(k, sign_with \\ nil) do
    fields = %{
      "v" => 1,
      "alg" => "EdDSA",
      "kid" => k.kid,
      "effect_digest" => "sha256:" <> String.duplicate("cd", 32),
      "principal" => "agent:c3",
      "policy_epoch" => 1,
      "revocation_epoch" => 0,
      "generation" => 1,
      "nonce" => "n-" <> k.kid,
      "not_before" => @now - 60,
      "expires" => @now + 300,
      "audience" => @aud
    }

    {:ok, bytes} = SignedMessage.build(fields)
    sig = :crypto.sign(:eddsa, :none, bytes, [sign_with || k.priv, :ed25519])

    env = %Envelope{
      v: 1,
      alg: "EdDSA",
      kid: k.kid,
      profile: :classical,
      signed_bytes_digest: SignedMessage.digest(bytes),
      signature: sig,
      nonce: fields["nonce"],
      not_before: fields["not_before"],
      expires: fields["expires"],
      audience: @aud
    }

    {env, bytes}
  end

  defp policy(k), do: %{k: k, audience: @aud, now: @now}

  test "two kids of one custodian are one signer; two custodians are a quorum" do
    [a1, a2, b] = ks = [key("A"), key("A"), key("B")]
    view = Static.view(Enum.map(ks, & &1.record))

    assert {:error, :quorum_not_met} =
             SignerSet.evaluate([approve(a1), approve(a2)], nil, view, policy(2))

    assert {:ok, %{custodians: ["A", "B"], tier: :i2}} =
             SignerSet.evaluate([approve(a1), approve(a2), approve(b)], nil, view, policy(2))
  end

  test "a signer label without a verifiable signature counts zero" do
    [a, b] = ks = [key("A"), key("B")]
    attacker = key("evil")
    view = Static.view(Enum.map(ks, & &1.record))
    forged = approve(b, attacker.priv)

    assert {:error, :quorum_not_met} =
             SignerSet.evaluate([approve(a), forged], nil, view, policy(2))

    # the legacy shape (`%{signer: label}`) is not evidence of anything
    assert {:error, :quorum_not_met} =
             SignerSet.evaluate(
               [approve(a), {%{signer: "B", custodian_id: "B"}, "x"}],
               nil,
               view,
               policy(2)
             )
  end

  test "quorum/2 over standings counts distinct custodians of valid standings only" do
    valid = fn kid, c, t -> {:valid, %{kid: kid, custodian_id: c, tier: t, epoch: 0}} end

    assert {:error, :quorum_not_met} =
             SignerSet.quorum([valid.("k1", "c1", :i2), valid.("k2", "c1", :i2)], 2)

    assert {:error, :quorum_not_met} =
             SignerSet.quorum([valid.("k1", "c1", :i2), {:invalid, :bad_signature}], 2)

    assert {:error, :quorum_not_met} = SignerSet.quorum([], 2)

    assert {:ok, %{custodians: ["c1", "c2"], tier: :i1}} =
             SignerSet.quorum([valid.("k1", "c1", :i2), valid.("k2", "c2", :i1)], 2)
  end

  test "the label-counting threshold?/2 is gone" do
    Code.ensure_loaded!(SignerSet)
    refute function_exported?(SignerSet, :threshold?, 2)
  end
end
