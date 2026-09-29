defmodule AshA2A.SA2A.Conformance.Checks.ProbeFixtures do
  @moduledoc """
  Real cryptographic fixtures for the C2/C3 probes: real Ed25519 keys, real
  `Sa2aCrypto` registry records and views, real signatures over the RFC-007
  domain-separated approval message (`AshA2A.CryptoStanding.signed_message/1`).
  The oracle for validity is `:crypto.sign/4`, independent of the verifier under
  probe. `Sa2aCrypto` is reached through runtime `apply`/`struct` so this
  module compiles even if that project is absent (the probe then fails closed).
  """

  alias AshA2A.C2.{Certificate, PreparedEffect}

  @now 1_800_000_000
  @audience "actuator:conformance-probe"
  @principal "conformance-probe-principal"

  def now, do: @now
  def audience, do: @audience
  def principal, do: @principal

  @spec available?() :: boolean()
  def available? do
    Enum.all?(
      [Sa2aCrypto, Sa2aCrypto.KeyRecord, Sa2aCrypto.KeyRef, Sa2aCrypto.Registry.Static],
      &Code.ensure_loaded?/1
    )
  end

  @doc "A real Ed25519 signer registered under `custodian`."
  def signer(custodian, opts \\ []) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    kid = apply(Sa2aCrypto.KeyRef, :kid!, ["EdDSA", pub])

    rec =
      struct(
        Sa2aCrypto.KeyRecord,
        Keyword.merge(
          [
            kid: kid,
            alg: "EdDSA",
            public_key: pub,
            custodian_id: custodian,
            custody_tier: :i2,
            state: :active,
            revocation_epoch: 0
          ],
          Keyword.get(opts, :record, [])
        )
      )

    %{kid: kid, alg: "EdDSA", priv: priv, pub: pub, rec: rec}
  end

  def effect(payload \\ %{n: 1}),
    do: PreparedEffect.new(@principal, "conformance-cap", "subject", payload)

  def registry(signers),
    do: apply(Sa2aCrypto.Registry.Static, :view, [Enum.map(signers, & &1.rec)])

  def fields(effect, signer, over \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "alg" => signer.alg,
        "kid" => signer.kid,
        "effect_digest" => effect.digest,
        "principal" => effect.principal,
        "policy_epoch" => 5,
        "revocation_epoch" => 2,
        "generation" => 9,
        "nonce" => "n-#{signer.kid}",
        "not_before" => @now - 10,
        "expires" => @now + 100,
        "audience" => @audience
      },
      over
    )
  end

  @doc "A real signature entry over the approval message (oracle: `:crypto.sign`)."
  def sign(effect, signer, over \\ %{}) do
    {:ok, bytes} = AshA2A.CryptoStanding.signed_message(fields(effect, signer, over))

    %{
      signer: signer.kid,
      kid: signer.kid,
      alg: signer.alg,
      nonce: "n-#{signer.kid}",
      signature: :crypto.sign(:eddsa, :none, bytes, [signer.priv, :ed25519])
    }
  end

  def certificate(effect, sigs) do
    struct!(Certificate, %{
      effect_digest: effect.digest,
      principal: effect.principal,
      policy_epoch: 5,
      revocation_epoch: 2,
      generation: 9,
      signatures: sigs,
      v: 1,
      not_before: @now - 10,
      expires: @now + 100,
      audience: @audience
    })
  end

  def verify_ctx(signers) do
    %{
      policy_epoch: 5,
      revocation_epoch: 2,
      generation: 9,
      principal: @principal,
      registry: registry(signers),
      audience: @audience,
      now: @now
    }
  end
end
