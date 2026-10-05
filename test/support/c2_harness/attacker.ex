# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Attacker do
  @moduledoc """
  Forging toolkit available to arbitrary attacker code on the control-plane node. It signs
  with `:crypto` directly (no AshA2A or actuator function), using only keys the attacker
  legitimately holds: keys it generates itself and the compromised keys in
  `C2Harness.ControlPlane.compromised`.
  """
  alias Sa2aCrypto.KeyRef

  def now, do: System.os_time(:second)
  def b64(bin), do: Base.url_encode64(bin, padding: false)

  @doc "A fresh attacker-generated P-256 key (unregistered anywhere)."
  def own_key do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    %{pub: pub, priv: priv, kid: KeyRef.kid!("ES256", pub)}
  end

  @doc "A compromised registered key handed to the attacker by the threat model."
  def compromised(cp, name), do: Map.fetch!(cp.compromised, name)

  def digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc """
  Build an actuation certificate the way an authority would, but signed by the attacker.

  `sigs`: list of `%{key: %{priv, kid}, nonce: binary}` plus optional `:label_alg` (the `alg`
  string written into the entry AND the signed message) and `:label_kid` (a kid written
  instead of the signing key's, to spoof another signer).
  `opts` override certificate fields (`"v"`, `"principal"`, `"generation"`, `"not_before"`,
  `"expires"`, `"audience"`, `"policy_epoch"`, `"revocation_epoch"`, `"effect_digest"`).
  Returns the canonical JSON bytes.
  """
  def forge_cert(cp, effect_bytes, sigs, opts \\ %{}) do
    t = now()

    fields =
      Map.merge(
        %{
          "v" => 1,
          "effect_digest" => digest(effect_bytes),
          "principal" => "agent:alice",
          "policy_epoch" => cp.policy_epoch,
          "revocation_epoch" => cp.revocation_epoch,
          "generation" => 1,
          "not_before" => t - 60,
          "expires" => t + 300,
          "audience" => cp.audience
        },
        opts
      )

    entries =
      for s <- sigs do
        alg = Map.get(s, :label_alg, "ES256")
        kid = Map.get(s, :label_kid, s.key.kid)

        {:ok, msg} =
          Sa2aCrypto.SignedMessage.build(
            Map.merge(fields, %{"alg" => alg, "kid" => kid, "nonce" => s.nonce})
          )

        sig = :crypto.sign(:ecdsa, :sha256, msg, [s.key.priv, :secp256r1])
        %{"kid" => kid, "alg" => alg, "nonce" => s.nonce, "signature" => b64(sig)}
      end

    Jcs.encode(Map.put(fields, "signatures", entries))
  end

  def nonce, do: b64(:crypto.strong_rand_bytes(12))

  @doc "Decode canonical effect bytes, apply `fun`, re-encode canonically."
  def mutate_effect(bytes, fun), do: bytes |> Jason.decode!() |> fun.() |> Jcs.encode()

  @doc "Decode a certificate JSON, apply `fun`, re-encode (signatures are NOT re-made)."
  def mutate_cert(bytes, fun), do: bytes |> Jason.decode!() |> fun.() |> Jcs.encode()

  @doc "Same JSON value, non-canonical bytes (whitespace + reversed key order)."
  def noncanonical(effect_map) do
    body =
      effect_map
      |> Enum.sort(:desc)
      |> Enum.map_join(", ", fn {k, v} -> Jason.encode!(k) <> ": " <> Jason.encode!(v) end)

    "{ " <> body <> " }"
  end

  @doc "A human-approval wire object (real AuthorityService form) signed by `key` (attacker-held)."
  def approval(cp, key, digest, over \\ %{}) do
    t = now()

    fields =
      Map.merge(
        %{
          "v" => 1,
          "alg" => "ES256",
          "kid" => key.kid,
          "effect_digest" => digest,
          "principal" => "agent:alice",
          "policy_epoch" => cp.policy_epoch,
          "revocation_epoch" => 4,
          "generation" => 9,
          "nonce" => nonce(),
          "not_before" => t - 10,
          "expires" => t + 200,
          "audience" => cp.authority_audience
        },
        over
      )

    {:ok, bytes} = Sa2aCrypto.SignedMessage.build(fields)

    env = %Sa2aCrypto.Envelope{
      v: 1,
      alg: "ES256",
      kid: key.kid,
      profile: :classical,
      signed_bytes_digest: Sa2aCrypto.SignedMessage.digest(bytes),
      signature: :crypto.sign(:ecdsa, :sha256, bytes, [key.priv, :secp256r1]),
      nonce: fields["nonce"],
      not_before: fields["not_before"],
      expires: fields["expires"],
      audience: fields["audience"]
    }

    {:ok, json} = Sa2aCrypto.Envelope.encode(env)
    %{"envelope" => Jason.decode!(json), "message" => b64(bytes)}
  end
end
