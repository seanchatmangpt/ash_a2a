# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ActuatorProfile do
  @moduledoc """
  Adapter between the control-plane model (`PreparedEffect`, `Certificate`) and the byte
  contracts of the two separate services (docs/reference/c2-wire-interop.md).

  ## Effect

  `effect/2` maps a `PreparedEffect` of the *actuator profile* onto the exact canonical
  (RFC 8785) byte string that BOTH the authority service certifies and the actuator executes
  (`Actuator.Effect`, a total exact-key schema):

      capability  -> capability        subject -> subject      principal -> principal
      payload     -> %{"effect_type", "consequence_class", "effect_instance_id",
                       "resource_bounds", "params"}
      policy_epoch (request context)   v = 1

  The digest that certificates bind is `sha256:` over these bytes. It is NOT
  `PreparedEffect.digest` (that one is over the five-key control-plane view); the framed
  clients carry the actuator digest in the certificate and refuse a certificate whose digest
  differs from the bytes they are about to send.

  ## Certificate

  `certificate_from_authority/1` turns the authority service's `{"envelope", "message"}` reply
  into the canonical `AshA2A.C2.Certificate` (seconds -> milliseconds), and
  `certificate_json/1` renders a certificate as the actuator's certificate JSON (milliseconds
  -> seconds; refuses sub-second values). Neither function signs or verifies anything; the
  actuator verifies every signature against its own pinned registry.
  """
  alias AshA2A.C2.{Certificate, PreparedEffect}
  alias Sa2aCrypto.{Envelope, SignedMessage}

  @effect_keys ~w(effect_type consequence_class effect_instance_id resource_bounds params)

  @type actuator_effect :: %{map: map(), bytes: binary(), digest: binary()}

  @spec effect(PreparedEffect.t(), non_neg_integer()) ::
          {:ok, actuator_effect()} | {:error, atom()}
  def effect(%PreparedEffect{} = e, policy_epoch)
      when is_integer(policy_epoch) and policy_epoch >= 0 do
    with {:ok, view} <- PreparedEffect.portable_view(e),
         %{"payload" => %{} = payload, "subject" => subject} when is_binary(subject) <- view,
         true <-
           Enum.sort(Map.keys(payload)) == Enum.sort(@effect_keys) or {:error, :payload_profile} do
      map = %{
        "v" => 1,
        "principal" => view["principal"],
        "subject" => subject,
        "capability" => view["capability"],
        "consequence_class" => payload["consequence_class"],
        "effect_type" => payload["effect_type"],
        "effect_instance_id" => payload["effect_instance_id"],
        "resource_bounds" => payload["resource_bounds"],
        "policy_epoch" => policy_epoch,
        "params" => payload["params"]
      }

      bytes = Jcs.encode(map)
      {:ok, %{map: map, bytes: bytes, digest: SignedMessage.digest(bytes)}}
    else
      {:error, _} = e -> e
      _ -> {:error, :payload_profile}
    end
  rescue
    _ -> {:error, :payload_profile}
  end

  def effect(_, _), do: {:error, :payload_profile}

  @doc "Authority-service certificate reply -> canonical `Certificate` (threshold 1, one signature)."
  @spec certificate_from_authority(map()) :: {:ok, Certificate.t()} | {:error, atom()}
  def certificate_from_authority(%{"envelope" => env, "message" => msg})
      when is_map(env) and is_binary(msg) do
    with {:ok, json} <- Jason.encode(env) |> tag(:malformed_certificate),
         {:ok, envelope} <- Envelope.decode(json) |> tag(:malformed_certificate),
         {:ok, bytes} <- Envelope.b64(msg) |> tag(:malformed_certificate),
         true <-
           SignedMessage.digest(bytes) == envelope.signed_bytes_digest or
             {:error, :envelope_message_mismatch},
         {:ok, m} <- SignedMessage.parse(bytes) |> tag(:malformed_certificate),
         true <-
           (m["kid"] == envelope.kid and m["alg"] == envelope.alg and m["nonce"] == envelope.nonce) or
             {:error, :envelope_message_mismatch},
         {:ok, nb} <- seconds(m["not_before"]),
         {:ok, ex} <- seconds(m["expires"]) do
      {:ok,
       %Certificate{
         version: m["v"],
         effect_digest: m["effect_digest"],
         principal: m["principal"],
         policy_epoch: m["policy_epoch"],
         revocation_epoch: m["revocation_epoch"],
         generation: m["generation"],
         nonce: m["nonce"],
         not_before_ms: nb,
         expires_at_ms: ex,
         audience: m["audience"],
         threshold: 1,
         alg: m["alg"],
         kid: m["kid"],
         signatures: [
           %{
             signer: m["kid"],
             kid: m["kid"],
             alg: m["alg"],
             nonce: m["nonce"],
             signature: envelope.signature
           }
         ]
       }}
    end
  rescue
    _ -> {:error, :malformed_certificate}
  end

  def certificate_from_authority(_), do: {:error, :malformed_certificate}

  @doc "Actuator certificate JSON (JCS bytes): signed-message seconds, per-signature kid/alg/nonce."
  @spec certificate_json(Certificate.t()) :: {:ok, binary()} | {:error, atom()}
  def certificate_json(%Certificate{} = c) do
    with {:ok, {nb, ex}} <- Certificate.window_seconds(c),
         {:ok, sigs} <- signatures(c) do
      {:ok,
       Jcs.encode(%{
         "v" => c.version,
         "effect_digest" => c.effect_digest,
         "principal" => to_string(c.principal),
         "policy_epoch" => c.policy_epoch,
         "revocation_epoch" => c.revocation_epoch,
         "generation" => c.generation,
         "not_before" => nb,
         "expires" => ex,
         "audience" => c.audience,
         "signatures" => sigs
       })}
    end
  rescue
    _ -> {:error, :malformed_certificate}
  end

  defp signatures(%Certificate{signatures: [_ | _] = sigs} = c) do
    Enum.reduce_while(sigs, {:ok, []}, fn s, {:ok, acc} ->
      kid = g(s, :kid) || c.kid
      alg = g(s, :alg) || c.alg
      nonce = g(s, :nonce) || c.nonce
      raw = g(s, :signature)

      if is_binary(kid) and is_binary(alg) and is_binary(nonce) and is_binary(raw) do
        {:cont,
         {:ok,
          [
            %{
              "kid" => kid,
              "alg" => alg,
              "nonce" => nonce,
              "signature" => Base.url_encode64(raw, padding: false)
            }
            | acc
          ]}}
      else
        {:halt, {:error, :malformed_certificate}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp signatures(_), do: {:error, :malformed_certificate}

  defp g(m, k) when is_map(m), do: Map.get(m, k) || Map.get(m, Atom.to_string(k))
  defp g(_, _), do: nil

  defp seconds(s) when is_integer(s) and s >= 0, do: {:ok, Certificate.from_seconds(s)}
  defp seconds(_), do: {:error, :malformed_certificate}

  defp tag({:ok, _} = ok, _), do: ok
  defp tag(_, code), do: {:error, code}
end
