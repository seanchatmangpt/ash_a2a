defmodule Sa2aCrypto.Quorum do
  @moduledoc """
  k-of-n signer quorum over REGISTRY-VERIFIED signatures.

      evaluate(envelopes, message, registry, policy)
        :: {:ok, %{k, signers: [%{kid, custodian_id, tier, epoch}], custodians, tier}}
         | {:error, refusal}

  Every envelope is run through `Sa2aCrypto.verify_envelope/4`. `message` is the signed
  bytes: one binary for all envelopes, a `%{kid => bytes}` map, or a 1-arity function of
  the envelope; a list item may also be `{envelope, bytes}`. (The signed bytes embed the
  signer's `kid`, so distinct signers sign distinct bytes.) Signers only count together
  when they approved the SAME `effect_digest` (pin it with `policy.effect_digest`).
  Only `{:valid, _}` standings can count; an envelope that does not verify (bad signature,
  unknown or non-active kid, wrong audience, ...) is ignored, never counted. A claimed
  signer label carries no weight: identity is the registry `kid` reached through a
  verified signature. Counted signers are then

    * deduplicated by `kid` and by `custodian_id` (two kids of one custodian count once),
    * filtered to tier rank >= `policy.tier` (`:i1 < :i2 < :i3 < :i4`),
    * refused if the key is revoked (`:compromised`/`:destroyed`), or its
      `revocation_epoch` is greater than `policy.epoch` (key enrolled/revoked after the
      certificate's epoch), when `policy.epoch` is given,
    * restricted to `policy.signer_kids` when that allowlist (the "n") is given.

  Policy (map or keyword): `k` (required, pos int), `tier` (default `:i1`), `audience`
  (required, passed to the verifier; fail closed), `now`, `epoch`, `signer_kids`,
  and verifier options `provider`, `required_profile`, `allowed_algs`.

  Returns `{:error, :quorum_not_met}` when fewer than `k` distinct custodians remain,
  `{:error, :invalid_policy}` for a malformed policy. Replay is NOT consumed here; callers
  pair this with `Sa2aCrypto.NonceStore`.
  """
  alias Sa2aCrypto.{Registry, Standing}

  @rank %{i1: 1, i2: 2, i3: 3, i4: 4}
  @verify_opts [:audience, :now, :provider, :required_profile, :allowed_algs]

  @spec evaluate([term()], term(), {module(), term()}, map() | keyword()) ::
          {:ok, map()} | {:error, atom()}
  def evaluate(envelopes, message, registry, policy) when is_list(envelopes) do
    policy = Map.new(policy)

    with {:ok, k, min_tier} <- policy(policy) do
      opts = policy |> Map.take(@verify_opts) |> Map.to_list()

      groups =
        envelopes
        |> Enum.flat_map(&verified(&1, message, registry, opts))
        |> Enum.filter(fn {s, digest} ->
          eligible?(s, registry, policy, min_tier) and digest_ok?(digest, policy)
        end)
        |> Enum.group_by(fn {_, digest} -> digest end, fn {s, _} -> s end)
        |> Enum.map(fn {digest, ss} -> {digest, distinct(ss)} end)
        |> Enum.sort_by(fn {digest, ss} -> {-length(ss), digest} end)

      case groups do
        [{digest, signers} | _] when length(signers) >= k ->
          tier = signers |> Enum.map(& &1.tier) |> Enum.min_by(&@rank[&1])

          {:ok,
           %{
             k: k,
             signers: signers,
             custodians: Enum.map(signers, & &1.custodian_id),
             tier: tier,
             effect_digest: digest
           }}

        _ ->
          {:error, :quorum_not_met}
      end
    end
  end

  def evaluate(_, _, _, _), do: {:error, :invalid_policy}

  defp distinct(signers) do
    signers
    |> Enum.uniq_by(& &1.kid)
    |> Enum.sort_by(&{&1.custodian_id, &1.kid})
    |> Enum.uniq_by(& &1.custodian_id)
  end

  defp digest_ok?(digest, %{effect_digest: want}), do: digest == want
  defp digest_ok?(_, _), do: true

  @doc """
  Quorum over already-computed standings (what `AshA2A.CryptoStanding` returns per
  signature). Counts distinct custodians among `{:valid, _}` standings; everything else is
  ignored.
  """
  @spec from_standings([Standing.t()], pos_integer(), atom()) :: {:ok, map()} | {:error, atom()}
  def from_standings(standings, k, min_tier \\ :i1)

  def from_standings(standings, k, min_tier)
      when is_list(standings) and is_integer(k) and k > 0 and is_map_key(@rank, min_tier) do
    signers =
      standings
      |> Enum.flat_map(fn
        {:valid, %{kid: kid, custodian_id: c, tier: t} = s}
        when is_binary(kid) and is_binary(c) and is_map_key(@rank, t) ->
          if @rank[t] >= @rank[min_tier], do: [s], else: []

        _ ->
          []
      end)
      |> Enum.uniq_by(& &1.kid)
      |> Enum.sort_by(&{&1.custodian_id, &1.kid})
      |> Enum.uniq_by(& &1.custodian_id)

    if length(signers) >= k do
      tier = signers |> Enum.map(& &1.tier) |> Enum.min_by(&@rank[&1])

      {:ok,
       %{k: k, signers: signers, custodians: Enum.map(signers, & &1.custodian_id), tier: tier}}
    else
      {:error, :quorum_not_met}
    end
  end

  def from_standings(_, _, _), do: {:error, :invalid_policy}

  defp policy(%{k: k} = p) when is_integer(k) and k > 0 do
    tier = Map.get(p, :tier, :i1)

    cond do
      not is_map_key(@rank, tier) -> {:error, :invalid_policy}
      not is_binary(p[:audience]) -> {:error, :invalid_policy}
      true -> {:ok, k, tier}
    end
  end

  defp policy(_), do: {:error, :invalid_policy}

  # -> [{valid_standing, effect_digest}] or [] (unverifiable envelopes are ignored)
  defp verified(item, message, registry, opts) do
    {envelope, bytes} = pair(item, message)

    with true <- is_binary(bytes),
         {:valid, s} <- Sa2aCrypto.verify_envelope(envelope, bytes, registry, opts),
         {:ok, %{"effect_digest" => d}} <- Sa2aCrypto.SignedMessage.parse(bytes) do
      [{s, d}]
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp pair({env, bytes}, _) when is_binary(bytes), do: {env, bytes}
  defp pair(env, m) when is_binary(m), do: {env, m}
  defp pair(env, m) when is_function(m, 1), do: {env, m.(env)}
  defp pair(env, %{} = m), do: {env, Map.get(m, kid_of(env))}
  defp pair(env, _), do: {env, nil}

  defp kid_of(%{kid: k}), do: k
  defp kid_of(%{"kid" => k}), do: k
  defp kid_of(_), do: nil

  defp eligible?(s, registry, policy, min_tier) do
    with true <- @rank[s.tier] >= @rank[min_tier],
         true <- allowed_kid?(s.kid, policy),
         {:ok, rec} <- Registry.lookup(registry, s.kid),
         true <- rec.state not in [:compromised, :destroyed],
         true <- epoch_ok?(rec.revocation_epoch, policy[:epoch]) do
      true
    else
      _ -> false
    end
  end

  defp allowed_kid?(kid, %{signer_kids: kids}) when is_list(kids), do: kid in kids
  defp allowed_kid?(_, _), do: true

  defp epoch_ok?(rec_epoch, e) when is_integer(e), do: rec_epoch <= e
  defp epoch_ok?(_, _), do: true
end
