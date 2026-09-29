defmodule Sa2aCrypto.Fixtures do
  @moduledoc false
  # Real keys, real signatures: every fixture signs with :crypto directly (an oracle
  # independent of Sa2aCrypto.Native.verify) and returns the registry view + envelope.
  alias Sa2aCrypto.{Envelope, KeyRecord, KeyRef, Native, Registry.Static, SignedMessage}

  @audience "actuator:test"
  def audience, do: @audience
  def now, do: 1_800_000_000

  def base_fields(alg, kid, over \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "alg" => alg,
        "kid" => kid,
        "effect_digest" => "sha256:" <> String.duplicate("ab", 32),
        "principal" => "agent:alice",
        "policy_epoch" => 3,
        "revocation_epoch" => 7,
        "generation" => 11,
        "nonce" => "nonce-0001",
        "not_before" => now() - 60,
        "expires" => now() + 300,
        "audience" => @audience
      },
      over
    )
  end

  def keypair("ES256") do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    {pub, priv}
  end

  def keypair("EdDSA"), do: :crypto.generate_key(:eddsa, :ed25519)

  def keypair(alg) do
    case Sa2aCrypto.Suite.hybrid_parts(alg) do
      {:ok, {c, p}} ->
        {cpub, cpriv} = keypair(c)
        {ppub, ppriv} = keypair(p)
        {{cpub, ppub}, {cpriv, ppriv}}

      :error ->
        :crypto.generate_key(Sa2aCrypto.Suite.pq_atom(alg), [])
    end
  end

  # raw signing with :crypto (independent oracle), never via Native
  def raw_sign("ES256", msg, priv), do: :crypto.sign(:ecdsa, :sha256, msg, [priv, :secp256r1])
  def raw_sign("EdDSA", msg, priv), do: :crypto.sign(:eddsa, :none, msg, [priv, :ed25519])

  def raw_sign(alg, msg, priv) do
    case Sa2aCrypto.Suite.hybrid_parts(alg) do
      {:ok, {c, p}} ->
        {cpriv, ppriv} = priv
        Native.join_hybrid(raw_sign(c, msg, cpriv), raw_sign(p, msg, ppriv))

      :error ->
        :crypto.sign(Sa2aCrypto.Suite.pq_atom(alg), :none, msg, priv)
    end
  end

  @doc "Returns %{env, bytes, view, key, priv, kid} for a freshly generated key."
  def signed(alg \\ "ES256", over \\ %{}, key_over \\ []) do
    {pub, priv} = keypair(alg)
    kid = KeyRef.kid!(alg, pub)

    record =
      struct!(
        KeyRecord,
        Keyword.merge(
          [
            kid: kid,
            alg: alg,
            public_key: pub,
            custodian_id: "custodian-1",
            custody_tier: :i2,
            state: :active,
            revocation_epoch: 7
          ],
          key_over
        )
      )

    fields = base_fields(alg, kid, over)
    {:ok, bytes} = SignedMessage.build(fields)
    sig = raw_sign(alg, bytes, priv)

    %{
      env: envelope(fields, bytes, sig),
      bytes: bytes,
      view: Static.view([record]),
      key: record,
      priv: priv,
      kid: kid,
      fields: fields,
      sig: sig
    }
  end

  def envelope(fields, bytes, sig) do
    alg = fields["alg"]

    %Envelope{
      v: fields["v"],
      alg: alg,
      kid: fields["kid"],
      profile: Sa2aCrypto.Suite.profile_of(alg),
      signed_bytes_digest: SignedMessage.digest(bytes),
      signature: sig,
      nonce: fields["nonce"],
      not_before: fields["not_before"],
      expires: fields["expires"],
      audience: fields["audience"]
    }
  end

  def opts(extra \\ []), do: Keyword.merge([now: now(), audience: @audience], extra)

  def unhex(s), do: Base.decode16!(s, case: :mixed)
end
