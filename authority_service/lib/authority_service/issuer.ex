defmodule AuthorityService.Issuer do
  @moduledoc """
  Issue-only core. Serialized through one process so journal order equals issuance order.

  `issue/3` takes a decoded wire request (string keys):

      %{"effect" => b64url canonical bytes, "effect_digest" => "sha256:..", "audience" =>
        actuator id, "generation" => n, "approvals" => [%{"envelope" => map, "message" => b64url}]}

  and returns `{:ok, %{"envelope", "message"}}` (an ActuationCertificate in the SA2A signed
  message form, audience = actuator id) or `{:refused, code, detail}`. The service never
  executes effects and holds no actuator credentials. Crypto standing (Sa2aCrypto) is
  certified evidence; this module decides issuance from standing + policy.

  Refusal codes: `:malformed_request`, `:digest_mismatch`, `:malformed_effect`,
  `:non_canonical_effect`, `:unknown_effect_class`, `:already_issued`,
  `:insufficient_approvals` (detail = per-approval refusal codes), `:journal_failed`,
  `:sign_failed`.
  """
  use GenServer
  alias AuthorityService.{Config, Journal, Policy}
  alias Sa2aCrypto.{Envelope, SignedMessage}

  @max_effect_bytes 16_384

  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)

    gen_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, config, gen_opts)
  end

  @spec issue(GenServer.server(), map(), keyword()) ::
          {:ok, map()} | {:refused, atom(), list()}
  def issue(server, request, opts \\ []) do
    GenServer.call(server, {:issue, request, Keyword.get(opts, :now)}, 15_000)
  end

  @impl true
  def init(%Config{} = config) do
    case Journal.open(config.journal_path) do
      {:ok, journal} -> {:ok, %{config: config, journal: journal}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:issue, request, now}, _from, %{config: c, journal: j} = st) do
    now = now || now(c)

    case do_issue(request, now, c, j) do
      {:ok, cert, j2} -> {:reply, {:ok, cert}, %{st | journal: j2}}
      {:refused, _, _} = r -> {:reply, r, st}
    end
  end

  defp now(%Config{clock: f}) when is_function(f, 0), do: f.()
  defp now(_), do: System.os_time(:second)

  @impl true
  def terminate(_, %{journal: j}), do: Journal.close(j)

  defp do_issue(request, now, c, j) do
    with {:ok, req} <- parse_request(request, c.policy),
         :ok <- digest_ok(req),
         {:ok, effect} <- parse_effect(req.effect),
         {:ok, k} <- required(c.policy, effect),
         :ok <- not_issued(j, req),
         {:ok, counted} <- gather_approvals(req, effect, k, now, c, j) do
      mint(req, effect, k, counted, now, c, j)
    else
      {:error, code} -> {:refused, code, []}
      {:error, code, detail} -> {:refused, code, detail}
    end
  end

  # ---- request ----------------------------------------------------------

  defp parse_request(
         %{"effect" => eff, "effect_digest" => dig, "audience" => aud, "generation" => gen} = r,
         policy
       )
       when is_binary(eff) and is_binary(dig) and is_binary(aud) and aud != "" and
              is_integer(gen) and gen >= 0 do
    approvals = Map.get(r, "approvals", [])

    with {:ok, bytes} <- Envelope.b64(eff) |> tag(:malformed_request),
         true <- byte_size(bytes) <= @max_effect_bytes or {:error, :malformed_request},
         true <-
           (is_list(approvals) and length(approvals) <= policy.max_approvals) or
             {:error, :malformed_request} do
      {:ok, %{effect: bytes, digest: dig, audience: aud, generation: gen, approvals: approvals}}
    else
      _ -> {:error, :malformed_request}
    end
  end

  defp parse_request(_, _), do: {:error, :malformed_request}

  defp tag({:ok, _} = ok, _), do: ok
  defp tag(_, code), do: {:error, code}

  defp digest_ok(%{effect: bytes, digest: presented}) do
    if SignedMessage.digest(bytes) == presented, do: :ok, else: {:error, :digest_mismatch}
  end

  # The digest is recomputed from the presented bytes; class/amount/principal are read from
  # those bytes, never from side fields of the request.
  defp parse_effect(bytes) do
    with {:ok, term} <- Jason.decode(bytes) |> tag(:malformed_effect),
         {:ok, map} <- SignedMessage.normalize(term) |> tag(:malformed_effect),
         true <- Jcs.encode(map) == bytes or {:error, :non_canonical_effect},
         true <- is_binary(map["effect_class"]) or {:error, :malformed_effect},
         true <- (is_integer(map["amount"]) and map["amount"] >= 0) or {:error, :malformed_effect},
         true <-
           (is_binary(map["principal"]) and map["principal"] != "") or {:error, :malformed_effect} do
      {:ok, map}
    else
      {:error, code} -> {:error, code}
    end
  rescue
    _ -> {:error, :malformed_effect}
  end

  defp required(policy, %{"effect_class" => cls, "amount" => amt}) do
    Policy.required(policy, cls, amt)
  end

  defp not_issued(j, %{digest: d, generation: g}) do
    if Journal.issued?(j, d, g), do: {:error, :already_issued}, else: :ok
  end

  # ---- approvals --------------------------------------------------------

  defp gather_approvals(_req, _effect, 0, _now, _c, _j), do: {:ok, []}

  defp gather_approvals(req, effect, k, now, c, j) do
    ctx = %{req: req, effect: effect, now: now, c: c, j: j}
    acc0 = %{counted: %{}, seen: MapSet.new(), detail: []}

    acc = Enum.reduce(req.approvals, acc0, &take(parse_approval(&1), &2, ctx))
    acc = if map_size(acc.counted) < k, do: solicit(acc, k, ctx), else: acc

    if map_size(acc.counted) >= k do
      {:ok, Map.values(acc.counted)}
    else
      {:error, :insufficient_approvals, Enum.reverse(acc.detail)}
    end
  end

  defp parse_approval(%{"envelope" => env, "message" => msg})
       when is_map(env) and is_binary(msg) do
    with {:ok, json} <- Jason.encode(env) |> tag(:malformed_approval),
         {:ok, e} <- Envelope.decode(json) |> tag(:malformed_approval),
         {:ok, bytes} <- Envelope.b64(msg) |> tag(:malformed_approval) do
      {:ok, %{envelope: e, message: bytes}}
    end
  rescue
    _ -> {:error, :malformed_approval}
  end

  defp parse_approval(_), do: {:error, :malformed_approval}

  defp take({:error, code}, acc, _ctx), do: %{acc | detail: [code | acc.detail]}

  defp take({:ok, a}, acc, ctx) do
    case check(a, acc.seen, ctx) do
      {:ok, standing, msg} ->
        key = {a.envelope.kid, a.envelope.nonce}
        seen = MapSet.put(acc.seen, key)

        if Map.has_key?(acc.counted, standing.custodian_id) do
          %{acc | seen: seen, detail: [:duplicate_custodian | acc.detail]}
        else
          rec = %{
            custodian: standing.custodian_id,
            kid: standing.kid,
            nonce: a.envelope.nonce,
            expires: msg["expires"]
          }

          %{acc | seen: seen, counted: Map.put(acc.counted, standing.custodian_id, rec)}
        end

      {:error, code} ->
        %{acc | detail: [code | acc.detail]}
    end
  end

  defp solicit(acc, _k, %{c: %{channel: nil}}), do: acc

  defp solicit(acc, k, %{c: %{channel: {mod, state}} = c, req: req, effect: effect} = ctx) do
    request = %{
      effect: req.effect,
      effect_digest: req.digest,
      principal: effect["principal"],
      policy_epoch: c.policy.epoch,
      generation: req.generation,
      audience: c.authority_audience
    }

    c.policy.approvers
    |> Enum.reject(&Map.has_key?(acc.counted, &1))
    |> Enum.reduce_while(acc, fn approver, acc ->
      if map_size(acc.counted) >= k do
        {:halt, acc}
      else
        case mod.solicit(state, approver, request) do
          {:ok, %{envelope: env, message: bytes}} ->
            {:cont, take({:ok, %{envelope: env, message: bytes}}, acc, ctx)}

          {:error, code} ->
            {:cont, %{acc | detail: [:"channel_#{code}" | acc.detail]}}
        end
      end
    end)
  end

  defp check(%{envelope: env, message: bytes}, seen, %{
         req: req,
         effect: effect,
         now: now,
         c: c,
         j: j
       }) do
    policy = c.policy

    with {:ok, standing} <- standing(env, bytes, now, c),
         {:ok, msg} <- SignedMessage.parse(bytes) |> tag(:approval_malformed_message),
         :ok <- eq(msg["effect_digest"], req.digest, :approval_effect_mismatch),
         :ok <- epoch(msg["policy_epoch"], policy.epoch),
         :ok <- eq(msg["principal"], effect["principal"], :approval_principal_mismatch),
         :ok <- eq(msg["generation"], req.generation, :approval_generation_mismatch),
         :ok <- eq(msg["revocation_epoch"], standing.epoch, :approval_revocation_epoch_mismatch),
         :ok <- ttl(msg, policy),
         :ok <- tier(standing, policy),
         :ok <- registered(standing, policy),
         :ok <- replay(env, seen, j) do
      {:ok, standing, msg}
    end
  end

  defp standing(env, bytes, now, c) do
    verify = fn at ->
      Sa2aCrypto.verify_envelope(env, bytes, c.approver_registry,
        now: at,
        audience: c.authority_audience,
        required_profile: :classical
      )
    end

    # clock skew: an approval signed up to `skew` seconds in our future is accepted
    result =
      case verify.(now) do
        {:invalid, :not_yet_valid} -> verify.(now + c.policy.skew)
        other -> other
      end

    case result do
      {:valid, s} -> {:ok, s}
      {:invalid, code} -> {:error, :"approval_#{code}"}
    end
  end

  defp eq(a, a, _), do: :ok
  defp eq(_, _, code), do: {:error, code}

  defp epoch(e, e), do: :ok
  defp epoch(e, cur) when is_integer(e) and e < cur, do: {:error, :stale_policy_epoch}
  defp epoch(_, _), do: {:error, :policy_epoch_mismatch}

  defp ttl(%{"expires" => e, "not_before" => nb}, policy)
       when is_integer(e) and is_integer(nb) do
    if e - nb <= policy.human_ttl, do: :ok, else: {:error, :approval_ttl_exceeded}
  end

  defp ttl(_, _), do: {:error, :approval_malformed_message}

  defp tier(%{tier: t}, policy) do
    if Policy.tier_rank(t) >= Policy.tier_rank(policy.min_approver_tier),
      do: :ok,
      else: {:error, :approver_tier_too_low}
  end

  defp registered(%{custodian_id: id}, policy) do
    if id in policy.approvers, do: :ok, else: {:error, :approver_not_registered}
  end

  defp replay(env, seen, j) do
    key = {env.kid, env.nonce}

    if MapSet.member?(seen, key) or Journal.approval_seen?(j, env.kid, env.nonce),
      do: {:error, :approval_replayed},
      else: :ok
  end

  # ---- minting ----------------------------------------------------------

  defp mint(req, effect, k, counted, now, c, j) do
    policy = c.policy
    ttl = if k == 0, do: policy.automated_ttl, else: policy.human_ttl
    expires = Enum.reduce(counted, now + ttl, fn %{expires: e}, acc -> min(e, acc) end)
    key = c.service_key
    nonce = fresh_nonce(j)

    fields = %{
      "v" => 1,
      "alg" => key.alg,
      "kid" => key.kid,
      "effect_digest" => req.digest,
      "principal" => effect["principal"],
      "policy_epoch" => policy.epoch,
      "revocation_epoch" => key.revocation_epoch,
      "generation" => req.generation,
      "nonce" => nonce,
      "not_before" => now,
      "expires" => expires,
      "audience" => req.audience
    }

    entry = %{
      "cert_kid" => key.kid,
      "nonce" => nonce,
      "effect_digest" => req.digest,
      "generation" => req.generation,
      "audience" => req.audience,
      "expires" => expires,
      "approvals" => Enum.map(counted, &[&1.kid, &1.nonce])
    }

    # reserve durably (fsync) BEFORE signing: a crash after this point burns the nonce
    with {:ok, bytes} <- SignedMessage.build(fields) |> tag(:sign_failed),
         {:ok, j2} <- Journal.append(j, entry) |> tag(:journal_failed),
         {:ok, sig} <-
           Sa2aCrypto.Native.sign(key.alg, bytes, key.private_key) |> tag(:sign_failed) do
      env = %Envelope{
        v: 1,
        alg: key.alg,
        kid: key.kid,
        profile: :classical,
        signed_bytes_digest: SignedMessage.digest(bytes),
        signature: sig,
        nonce: nonce,
        not_before: now,
        expires: expires,
        audience: req.audience
      }

      {:ok, json} = Envelope.encode(env)

      {:ok,
       %{
         "envelope" => Jason.decode!(json),
         "message" => Base.url_encode64(bytes, padding: false)
       }, j2}
    else
      {:error, code} -> {:refused, code, []}
    end
  end

  defp fresh_nonce(j) do
    n = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    if Journal.nonce_seen?(j, n), do: fresh_nonce(j), else: n
  end
end
