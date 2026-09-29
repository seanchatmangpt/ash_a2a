defmodule Sa2aCrypto do
  @moduledoc """
  Affidavit-shaped cryptographic standing substrate for SA2A.

  `verify_envelope/4` returns a `Sa2aCrypto.Standing`: `{:valid, %{kid, custodian_id,
  tier, epoch}}` or `{:invalid, refusal_code}`. Standing certifies; it never authorizes.

  Options: `:now` (unix seconds, default now), `:audience` (REQUIRED, fail closed),
  `:required_profile` (default `:classical`), `:provider` (default `Sa2aCrypto.Native`),
  `:allowed_algs` (default: all registered suites).

  Refusal codes: `:malformed_envelope`, `:unsupported_algorithm`, `:unsupported_suite`
  (registered suite whose provider is absent on this runtime), `:profile_mismatch`,
  `:profile_downgrade`, `:unknown_kid`, `:key_<state>` (`:key_suspended`, `:key_compromised`,
  ...), `:key_expired`, `:alg_mismatch`, `:kid_key_mismatch`, `:bad_key`, `:audience_required`,
  `:wrong_audience`, `:not_yet_valid`, `:expired`, `:bad_domain`, `:malformed_message`,
  `:message_envelope_mismatch`, `:digest_mismatch`, `:bad_signature`.

  Replay protection is keyed on `Sa2aCrypto.Envelope.replay_key/1` (`{kid, nonce}`) by the
  caller's durable store, never on signature bytes.
  """
  alias Sa2aCrypto.{Envelope, KeyRecord, KeyRef, Registry, SignedMessage, Standing, Suite}

  @spec verify_envelope(Envelope.t() | map(), binary(), {module(), term()}, keyword()) ::
          Standing.t()
  def verify_envelope(envelope, message_bytes, registry_view, opts \\ []) do
    now = Keyword.get(opts, :now) || System.os_time(:second)
    provider = Keyword.get(opts, :provider, Sa2aCrypto.Native)
    required = Keyword.get(opts, :required_profile, :classical)

    with {:ok, env} <- Envelope.from_map(envelope) |> refuse(:malformed_envelope),
         :ok <- allowed(env.alg, opts),
         :ok <- profile(env, required),
         :ok <- provider_ready(provider, env.alg),
         {:ok, key} <- Registry.lookup(registry_view, env.kid) |> refuse(:unknown_kid),
         :ok <- key_usable(key, env, now),
         :ok <- audience(env, opts),
         :ok <- window(env, now),
         :ok <- binds(env, message_bytes),
         :ok <-
           provider.verify(env.alg, message_bytes, env.signature, key.public_key) |> sig_result() do
      {:valid,
       %{
         kid: key.kid,
         custodian_id: key.custodian_id,
         tier: key.custody_tier,
         epoch: key.revocation_epoch
       }}
    else
      {:error, code} when is_atom(code) -> {:invalid, code}
    end
  rescue
    _ -> {:invalid, :malformed_envelope}
  end

  defp refuse({:ok, _} = ok, _), do: ok
  defp refuse(_, code), do: {:error, code}

  defp allowed(alg, opts) do
    cond do
      is_nil(Suite.profile_of(alg)) -> {:error, :unsupported_algorithm}
      (a = Keyword.get(opts, :allowed_algs)) && alg not in a -> {:error, :unsupported_algorithm}
      true -> :ok
    end
  end

  defp profile(env, required) do
    cond do
      not Envelope.profile_matches_alg?(env) -> {:error, :profile_mismatch}
      not Suite.satisfies?(env.profile, required) -> {:error, :profile_downgrade}
      true -> :ok
    end
  end

  defp provider_ready(provider, alg) do
    if provider.supports?(alg), do: :ok, else: {:error, :unsupported_suite}
  end

  defp key_usable(%KeyRecord{} = key, env, now) do
    cond do
      key.state != :active -> {:error, :"key_#{key.state}"}
      is_integer(key.not_after) and now > key.not_after -> {:error, :key_expired}
      key.alg != env.alg -> {:error, :alg_mismatch}
      KeyRef.kid(key.alg, key.public_key) != {:ok, env.kid} -> {:error, :kid_key_mismatch}
      true -> :ok
    end
  end

  defp audience(env, opts) do
    case Keyword.get(opts, :audience) do
      a when is_binary(a) -> if env.audience == a, do: :ok, else: {:error, :wrong_audience}
      _ -> {:error, :audience_required}
    end
  end

  defp window(env, now) do
    cond do
      env.expires <= env.not_before -> {:error, :malformed_envelope}
      now < env.not_before -> {:error, :not_yet_valid}
      now >= env.expires -> {:error, :expired}
      true -> :ok
    end
  end

  # The envelope's claimed fields must be the ones inside the signed bytes, and the
  # digest must be of exactly the bytes the signature covers.
  defp binds(env, bytes) do
    with true <-
           SignedMessage.digest(bytes) == env.signed_bytes_digest or {:error, :digest_mismatch},
         {:ok, msg} <- SignedMessage.parse(bytes),
         true <-
           (msg["v"] == env.v and msg["alg"] == env.alg and msg["kid"] == env.kid and
              msg["nonce"] == env.nonce and msg["not_before"] == env.not_before and
              msg["expires"] == env.expires and msg["audience"] == env.audience) or
             {:error, :message_envelope_mismatch} do
      :ok
    end
  end

  defp sig_result(:ok), do: :ok
  defp sig_result({:error, :provider_required}), do: {:error, :unsupported_suite}
  defp sig_result({:error, code}), do: {:error, code}
end
