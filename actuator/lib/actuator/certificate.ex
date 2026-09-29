defmodule Actuator.Certificate do
  @moduledoc """
  Actuation certificate as the actuator receives it: JSON with a total schema.

      {v, effect_digest, principal, policy_epoch, revocation_epoch, generation,
       not_before, expires, audience,
       signatures: [{kid, alg, nonce, signature(base64url)}]}

  A certificate carries NO public keys and NO standing claims; unknown fields are refused,
  so a key smuggled in the body is a malformed certificate, not an input to verification.
  Each signature signs `Sa2aCrypto.SignedMessage` built from the certificate-level fields
  plus that signature's own `alg`, `kid` and `nonce`.
  """
  alias Sa2aCrypto.{Envelope, SignedMessage}

  @keys ~w(v effect_digest principal policy_epoch revocation_epoch generation not_before
           expires audience signatures)
  @sig_keys ~w(kid alg nonce signature)
  @max_bytes 65_536
  @max_sigs 8
  @max_int 9_007_199_254_740_991

  @enforce_keys [
    :v,
    :effect_digest,
    :principal,
    :policy_epoch,
    :revocation_epoch,
    :generation,
    :not_before,
    :expires,
    :audience,
    :signatures
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, m} when is_map(m) <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(m)) == Enum.sort(@keys),
         true <- ints?(m),
         true <-
           Enum.all?(~w(effect_digest principal audience), &(is_binary(m[&1]) and m[&1] != "")),
         true <- Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, m["effect_digest"]),
         {:ok, sigs} <- sigs(m["signatures"]) do
      {:ok,
       %__MODULE__{
         v: m["v"],
         effect_digest: m["effect_digest"],
         principal: m["principal"],
         policy_epoch: m["policy_epoch"],
         revocation_epoch: m["revocation_epoch"],
         generation: m["generation"],
         not_before: m["not_before"],
         expires: m["expires"],
         audience: m["audience"],
         signatures: sigs
       }}
    else
      _ -> {:error, :malformed_certificate}
    end
  end

  def decode(_), do: {:error, :malformed_certificate}

  defp ints?(m) do
    Enum.all?(~w(v policy_epoch revocation_epoch generation not_before expires), fn k ->
      is_integer(m[k]) and m[k] >= 0 and m[k] <= @max_int
    end)
  end

  defp sigs(l) when is_list(l) and l != [] and length(l) <= @max_sigs do
    Enum.reduce_while(l, {:ok, []}, fn s, {:ok, acc} ->
      with true <- is_map(s) and Enum.sort(Map.keys(s)) == Enum.sort(@sig_keys),
           true <- Enum.all?(~w(kid alg nonce), &(is_binary(s[&1]) and s[&1] != "")),
           true <- is_binary(s["signature"]),
           {:ok, raw} <- Envelope.b64(s["signature"]) do
        {:cont, {:ok, [%{kid: s["kid"], alg: s["alg"], nonce: s["nonce"], signature: raw} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      _ -> :error
    end
  end

  defp sigs(_), do: :error

  @doc "Signed message bytes for one signature entry, rebuilt by the verifier."
  @spec signed_message(t(), map()) :: {:ok, binary()} | {:error, atom()}
  def signed_message(%__MODULE__{} = c, sig) do
    SignedMessage.build(%{
      "v" => c.v,
      "alg" => sig.alg,
      "kid" => sig.kid,
      "effect_digest" => c.effect_digest,
      "principal" => c.principal,
      "policy_epoch" => c.policy_epoch,
      "revocation_epoch" => c.revocation_epoch,
      "generation" => c.generation,
      "nonce" => sig.nonce,
      "not_before" => c.not_before,
      "expires" => c.expires,
      "audience" => c.audience
    })
  end

  @doc "Envelope for one signature entry over `bytes` (built from certificate fields)."
  def envelope(%__MODULE__{} = c, sig, bytes) do
    %Envelope{
      v: c.v,
      alg: sig.alg,
      kid: sig.kid,
      profile: Sa2aCrypto.Suite.profile_of(sig.alg),
      signed_bytes_digest: SignedMessage.digest(bytes),
      signature: sig.signature,
      nonce: sig.nonce,
      not_before: c.not_before,
      expires: c.expires,
      audience: c.audience
    }
  end
end
