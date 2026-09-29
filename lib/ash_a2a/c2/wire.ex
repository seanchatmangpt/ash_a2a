defmodule AshA2A.C2.Wire do
  @moduledoc false

  alias AshA2A.C2.{AuthorityRequest, Certificate, PreparedEffect}

  def effect(%PreparedEffect{} = effect), do: PreparedEffect.portable_view(effect)

  def authority_request(%AuthorityRequest{} = request) do
    with {:ok, effect} <- effect(request.effect) do
      {:ok,
       %{
         "effect" => effect,
         "effect_digest" => request.effect_digest,
         "principal" => to_string(request.principal),
         "policy_epoch" => request.policy_epoch,
         "revocation_epoch" => request.revocation_epoch,
         "generation" => request.generation,
         "audience" => request.audience
       }}
    end
  end

  def certificate(%Certificate{} = cert) do
    %{
      "version" => cert.version,
      "effect_digest" => cert.effect_digest,
      "principal" => to_string(cert.principal),
      "policy_epoch" => cert.policy_epoch,
      "revocation_epoch" => cert.revocation_epoch,
      "generation" => cert.generation,
      "nonce" => cert.nonce,
      "not_before_ms" => cert.not_before_ms,
      "expires_at_ms" => cert.expires_at_ms,
      "audience" => cert.audience,
      "threshold" => cert.threshold,
      "signatures" => cert.signatures
    }
  end

  def decode_certificate(%{} = wire) do
    required = ~w(version effect_digest principal policy_epoch revocation_epoch generation nonce not_before_ms expires_at_ms audience threshold signatures)

    if Enum.all?(required, &Map.has_key?(wire, &1)) do
      {:ok,
       struct!(Certificate, %{
         version: wire["version"],
         effect_digest: wire["effect_digest"],
         principal: wire["principal"],
         policy_epoch: wire["policy_epoch"],
         revocation_epoch: wire["revocation_epoch"],
         generation: wire["generation"],
         nonce: wire["nonce"],
         not_before_ms: wire["not_before_ms"],
         expires_at_ms: wire["expires_at_ms"],
         audience: wire["audience"],
         threshold: wire["threshold"],
         signatures: wire["signatures"]
       })}
    else
      {:error, :invalid_certificate_wire}
    end
  end
end
