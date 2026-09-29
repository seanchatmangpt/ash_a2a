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
      "signatures" => Enum.map(cert.signatures, &wire_signature/1)
    }
    |> put_optional("alg", cert.alg)
    |> put_optional("kid", cert.kid)
  end

  # Signature entries carry raw bytes in-process; JSON carries base64url. An entry without
  # a `signature` binary (opaque external evidence) passes through unchanged.
  defp wire_signature(%{} = entry) do
    entry
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> case do
      %{"signature" => raw} = m when is_binary(raw) ->
        %{m | "signature" => Base.url_encode64(raw, padding: false)}

      m ->
        m
    end
  end

  defp wire_signature(other), do: other

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp decode_signature(%{"signature" => b64} = m) when is_binary(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, raw} ->
        {:ok,
         %{
           signer: m["signer"] || m["kid"],
           kid: m["kid"],
           alg: m["alg"],
           nonce: m["nonce"],
           signature: raw
         }}

      :error ->
        :error
    end
  end

  defp decode_signature(%{} = m), do: {:ok, m}
  defp decode_signature(_), do: :error

  def decode_certificate(%{} = wire) do
    required =
      ~w(version effect_digest principal policy_epoch revocation_epoch generation nonce not_before_ms expires_at_ms audience threshold signatures)

    with true <- Enum.all?(required, &Map.has_key?(wire, &1)),
         sigs when is_list(sigs) <- wire["signatures"],
         {:ok, decoded} <- decode_signatures(sigs) do
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
         signatures: decoded,
         alg: wire["alg"],
         kid: wire["kid"]
       })}
    else
      _ -> {:error, :invalid_certificate_wire}
    end
  end

  defp decode_signatures(sigs) do
    Enum.reduce_while(sigs, {:ok, []}, fn s, {:ok, acc} ->
      case decode_signature(s) do
        {:ok, d} -> {:cont, {:ok, [d | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end
end
