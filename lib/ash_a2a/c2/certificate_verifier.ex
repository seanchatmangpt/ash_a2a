defmodule AshA2A.C2.CertificateVerifier do
  @moduledoc """
  Verifies an actuation certificate: complete mediation first, then EVERY signature through
  `AshA2A.CryptoStanding` (Sa2aCrypto). Certify, don't decide: `:ok` means mediation passed
  and all signatures carry valid cryptographic standing; authorization stays with SA2A/BRCE.

  Per RFC-SA2A-007 E-E the signed message is rebuilt from durable state (`e.digest`, the
  certificate's epochs and generation, the ctx audience), never taken from the certificate
  body alone. `ctx` carries `:registry` (a `Sa2aCrypto.Registry` view), `:audience`, and
  optionally `:now` and `:required_profile`. A missing registry or audience fails closed.
  Replay protection (`{kid, nonce}`) is enforced by the durable claim store from the
  `:replay_key` returned by `standings/3`.
  """
  alias AshA2A.C2.{Certificate, CompleteMediation}
  alias AshA2A.CryptoStanding
  alias Sa2aCrypto.{Envelope, Suite}

  def verify(c, e, ctx) do
    case standings(c, e, ctx) do
      {:ok, _} -> :ok
      _ -> {:error, :certificate_refused}
    end
  end

  @doc """
  `{:ok, [%{standing, replay_key, kid, alg, nonce}]}` when every signature is valid, else
  `{:error, :refused}` (mediation) or `{:error, {:certificate_refused, [standing]}}`.
  """
  def standings(c, e, ctx) do
    with :ok <- CompleteMediation.admit(e, c, ctx) do
      case c.signatures do
        [_ | _] = sigs when is_list(sigs) ->
          results = Enum.map(sigs, &verify_one(&1, c, e, ctx))

          if Enum.all?(results, &CryptoStanding.valid?(&1.standing)),
            do: {:ok, results},
            else: {:error, {:certificate_refused, Enum.map(results, & &1.standing)}}

        _ ->
          {:error, {:certificate_refused, [{:invalid, :no_signatures}]}}
      end
    end
  end

  defp verify_one(sig, c, e, ctx) when is_map(sig) do
    alg = field(sig, :alg) || c.alg
    kid = field(sig, :kid) || c.kid
    nonce = field(sig, :nonce) || c.nonce
    raw = field(sig, :signature)
    audience = c.audience
    window = Certificate.window_seconds(c)

    {nb, ex} =
      case window do
        {:ok, {a, b}} -> {a, b}
        {:error, _} -> {nil, nil}
      end

    fields = %{
      "v" => c.version,
      "alg" => alg,
      "kid" => kid,
      "effect_digest" => e.digest,
      "principal" => e.principal,
      "policy_epoch" => c.policy_epoch,
      "revocation_epoch" => c.revocation_epoch,
      "generation" => c.generation,
      "nonce" => nonce,
      "not_before" => nb,
      "expires" => ex,
      "audience" => audience
    }

    standing =
      with true <- is_binary(raw) or {:invalid, :bad_signature},
           {:ok, _} <- window |> tag_window(),
           registry when not is_nil(registry) <- Map.get(ctx, :registry),
           {:ok, bytes} <- signed_message(fields),
           {:ok, env} <- envelope(fields, bytes, raw) do
        opts =
          [audience: Map.get(ctx, :audience), now: Map.get(ctx, :now)]
          |> Keyword.merge(
            case Map.get(ctx, :required_profile) do
              nil -> []
              p -> [required_profile: p]
            end
          )

        CryptoStanding.verify(env, bytes, registry, opts)
      else
        nil -> {:invalid, :no_registry}
        {:invalid, _} = i -> i
      end

    %{standing: standing, replay_key: {kid, nonce}, kid: kid, alg: alg, nonce: nonce}
  end

  defp verify_one(_sig, c, _e, _ctx),
    do: %{
      standing: {:invalid, :malformed_signature},
      replay_key: nil,
      kid: nil,
      alg: c.alg,
      nonce: nil
    }

  # a whole-second window is a precondition of the signed message (see Certificate moduledoc)
  defp tag_window({:ok, _} = ok), do: ok
  defp tag_window({:error, _}), do: {:invalid, :malformed_certificate}

  defp signed_message(fields) do
    case CryptoStanding.signed_message(fields) do
      {:ok, _} = ok -> ok
      {:error, code} -> {:invalid, malformed(code)}
    end
  end

  defp malformed(code) when code in [:missing_field, :bad_field_type], do: :malformed_certificate
  defp malformed(code), do: code

  defp envelope(fields, bytes, raw) do
    case Suite.profile_of(fields["alg"]) do
      nil ->
        {:invalid, :unsupported_algorithm}

      profile ->
        Envelope.from_map(%{
          "v" => fields["v"],
          "alg" => fields["alg"],
          "kid" => fields["kid"],
          "profile" => profile,
          "signed_bytes_digest" => Sa2aCrypto.SignedMessage.digest(bytes),
          "signature" => raw,
          "nonce" => fields["nonce"],
          "not_before" => fields["not_before"],
          "expires" => fields["expires"],
          "audience" => fields["audience"]
        })
        |> case do
          {:ok, _} = ok -> ok
          _ -> {:invalid, :malformed_envelope}
        end
    end
  end

  defp field(map, key), do: Map.get(map, key)
end
