defmodule AshA2A.C2.Certificate do
  @moduledoc """
  Actuation certificate.

  `signatures` is a list of `%{signer, kid, alg, nonce, signature}` maps (`signature` is raw
  bytes). `kid`, `alg` and `nonce` fall back to the certificate-level fields when a signature
  entry omits them. The signed bytes are rebuilt by the verifier
  (`AshA2A.C2.CertificateVerifier`) from durable state; nothing here is trusted as-is.
  `v`, `alg`, `kid`, `nonce`, `not_before`, `expires`, `audience` are bound into the
  signed message (RFC-SA2A-007 E-E).
  """
  @enforce_keys [
    :effect_digest,
    :principal,
    :policy_epoch,
    :revocation_epoch,
    :generation,
    :signatures
  ]
  defstruct @enforce_keys ++ [:alg, :kid, :nonce, :not_before, :expires, :audience, v: 1]
  def bound?(c, e), do: c.effect_digest == e.digest and c.principal == e.principal
end
