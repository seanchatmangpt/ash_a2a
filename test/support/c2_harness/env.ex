# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Env do
  @moduledoc """
  What an attack script sees. Two halves, deliberately separate:

    * `cp` (`C2Harness.ControlPlane`): the ATTACKER's capabilities. Attack code that
      forges, mutates, replays or injects uses only this plus its own `:crypto`.
    * court controls (`issue/3`, `approve/4`, `revoke/2`, `restart_actuator/2`, ...):
      OPERATOR-SIDE actions the court needs to stage a scenario (an authority that mis-issues,
      an operator revoking a key, a process being killed). They stand for things that happen
      in other trust domains, not for attacker powers, and each attack states which it uses.

  `submit/3` and friends record every refusal code / status the actuator returned into the
  run's observation table, which is how the court proves an attack actually reached the
  check it targets (a refusal for the wrong reason is `:vacuous`, not a pass).
  """
  alias C2Harness.{Fleet, Wire}

  @enforce_keys [:fleet, :cp, :n, :obs]
  defstruct [:fleet, :cp, :n, :obs, seed: {1, 2, 3}]

  @type t :: %__MODULE__{}

  def new(fleet, cp, n) do
    obs = :ets.new(:c2_obs, [:public, :bag])
    %__MODULE__{fleet: fleet, cp: cp, n: n, obs: obs}
  end

  @doc "Fresh valid effect map (unique instance id) for the `ledger_append` effector."
  def effect(over \\ %{}) do
    id = "ei:c2-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Map.merge(
      %{
        "v" => 1,
        "principal" => "agent:alice",
        "subject" => "subject:orders/42",
        "capability" => "actuator.ledger.append",
        "consequence_class" => "internal_append",
        "effect_type" => "ledger_append",
        "effect_instance_id" => id,
        "resource_bounds" => %{"max_bytes" => 256},
        "policy_epoch" => 3,
        "params" => %{"entry" => "c2-court-" <> id}
      },
      over
    )
  end

  def bytes(effect_map), do: Jcs.encode(effect_map)
  def digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  def now, do: System.os_time(:second)

  # ---- court controls (operator/authority side) ---------------------------------------------

  @doc """
  Obtain an actuation certificate in the actuator wire form.
  Returns `{:ok, %{effect, cert, digest, nonces}}` or `{:error, refusal}`.

  With no options this is an INTENDED issuance and it goes to the REAL AuthorityService
  processes only. The court actuator pins quorum 2, so two independent authorities (two keys,
  two custodian identities, two journals) each sign: approvals from bob and carol are attached
  to an `issue` request at authority 1; authority 2 receives the same approvals plus authority
  1's validity window (`"window"`, which it only accepts if it narrows its own policy); the two
  issued certificates are merged with `AuthorityService.Issuer.combine_actuator_certificates/1`.
  The keymaster signs nothing in this path.

  With any option the certificate comes from the keymaster stand-in (`issue_actuation`),
  because every option asks for something the real service refuses to do: `:journal` (false:
  a mis-issuance that is in no issuance journal), `:signers` (a chosen key set, e.g. the
  compromised A/A2 or a single custodian), `:generation`, `:not_before_off`, `:expires_off`,
  `:policy_epoch`, `:revocation_epoch`, `:audience`, `:principal`, `:v`, `:digest`, `:nonces`.
  """
  def issue(env, effect_map_or_bytes, opts \\ [])

  def issue(%__MODULE__{} = env, effect_map_or_bytes, []),
    do: issue_real(env, effect_map_or_bytes, [1, 2])

  def issue(%__MODULE__{fleet: f} = env, effect_map_or_bytes, opts) do
    eff =
      if is_binary(effect_map_or_bytes), do: effect_map_or_bytes, else: bytes(effect_map_or_bytes)

    track(env, :keymaster_standin)

    req =
      opts
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.merge(%{
        "op" => "issue_actuation",
        "effect" => Base.url_encode64(eff, padding: false)
      })

    km_issued(eff, Fleet.km(f, req))
  end

  @doc """
  An intended issuance from the REAL authorities named by `which` (`[1, 2]` both, `[1]` or
  `[2]` one). One authority is below the court actuator's quorum of 2; this exists to prove
  that. Authorities are asked in the order given; the later ones adopt the first one's window.
  """
  def issue_real(%__MODULE__{} = env, effect_map_or_bytes, which) do
    eff =
      if is_binary(effect_map_or_bytes), do: effect_map_or_bytes, else: bytes(effect_map_or_bytes)

    track(env, :real_authority)
    d = digest(eff)

    principal =
      case Jason.decode(eff) do
        {:ok, %{"principal" => p}} when is_binary(p) -> [principal: p]
        _ -> []
      end

    approvals = for n <- ["bob", "carol"], do: approve(env, n, d, [generation: 1] ++ principal)

    which
    |> Enum.reduce_while({:ok, [], nil}, fn n, {:ok, acc, window} ->
      case request_issue(env, n, eff, d, approvals, window) do
        {:ok, cert} -> {:cont, {:ok, acc ++ [cert], window || window_of(cert)}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, certs, _} ->
        with {:ok, m} <-
               km_issued(
                 eff,
                 Fleet.km(env.fleet, %{"op" => "combine_actuation", "certificates" => certs})
               ),
             do: {:ok, Map.put(m, :issued, certs)}

      {:error, _} = e ->
        e
    end
  end

  @doc """
  STAND-IN for a holder of authority 1's key: authority 1 really issues, then a second
  signature by the SAME key (fresh nonce, same fields) is appended by the keymaster. Two valid
  signatures, one custodian.
  """
  def reuse_authority_key(%__MODULE__{fleet: f} = env, effect_map_or_bytes) do
    with {:ok, %{issued: [cert]} = l} <- issue_real(env, effect_map_or_bytes, [1]) do
      track(env, :keymaster_standin)

      case km_issued(
             l.effect,
             Fleet.km(f, %{"op" => "reuse_authority_key", "certificate" => cert})
           ) do
        {:ok, again} -> {:ok, again}
        other -> other
      end
    end
  end

  def issue_real!(env, eff, which) do
    {:ok, l} = issue_real(env, eff, which)
    l
  end

  defp request_issue(env, n, eff, d, approvals, window) do
    sock = if n == 1, do: env.cp.authority_sock, else: env.cp.authority2_sock

    req =
      %{
        "op" => "issue",
        "effect" => Base.url_encode64(eff, padding: false),
        "effect_digest" => d,
        "audience" => env.cp.audience,
        "generation" => 1,
        "approvals" => approvals
      }
      |> then(&if window, do: Map.put(&1, "window", window), else: &1)

    case Wire.lp(sock, req) do
      {:ok, %{"ok" => true, "certificate" => cert}} -> {:ok, cert}
      {:ok, %{"refusal" => code}} -> {:error, code}
      other -> {:error, other}
    end
  end

  # the validity window an issued certificate carries (read from its signed message)
  defp window_of(%{"message" => msg}) do
    {:ok, bytes} = Base.url_decode64(msg, padding: false)
    {:ok, m} = Sa2aCrypto.SignedMessage.parse(bytes)
    %{"not_before" => m["not_before"], "expires" => m["expires"]}
  end

  defp km_issued(eff, reply) do
    case reply do
      {:ok, %{"ok" => true, "certificate" => c, "digest" => d, "nonces" => n}} ->
        {:ok, %{effect: eff, cert: Base.url_decode64!(c, padding: false), digest: d, nonces: n}}

      {:ok, %{"refusal" => code}} ->
        {:error, code}

      other ->
        {:error, other}
    end
  end

  # the table is a bag: a unique third element keeps one row per request
  defp track(%__MODULE__{obs: obs}, path),
    do: :ets.insert(obs, {:issuance, path, System.unique_integer()})

  @doc "How many certificates this run asked each issuer for."
  def issuance_paths(%__MODULE__{obs: obs}),
    do: obs |> :ets.lookup(:issuance) |> Enum.frequencies_by(&elem(&1, 1))

  def issue!(env, eff, opts \\ []) do
    {:ok, l} = issue(env, eff, opts)
    l
  end

  @doc "Mis-issuance: validly signed by a registered key set but NOT in the issuance journal."
  def misissue!(env, eff, opts \\ []), do: issue!(env, eff, Keyword.put(opts, :journal, false))

  @doc "A human approval in the real AuthorityService wire form (operator-side approver)."
  def approve(%__MODULE__{fleet: f}, name, digest, opts \\ []) do
    req =
      opts
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.merge(%{"op" => "approve", "name" => name, "digest" => digest})

    case Fleet.km(f, req) do
      {:ok, %{"ok" => true, "approval" => a}} -> a
      other -> raise "approve failed: #{inspect(other)}"
    end
  end

  def revoke(%__MODULE__{fleet: f}, view), do: Fleet.write_revocation(f, view)
  def restart_actuator(%__MODULE__{fleet: f}, opts \\ []), do: Fleet.start_actuator(f, opts)
  def kill_actuator(%__MODULE__{fleet: f}), do: Fleet.kill_actuator(f)
  def arm_crash(%__MODULE__{fleet: f}, point), do: Fleet.arm_crash(f, point)
  def at_fault(%__MODULE__{fleet: f}), do: Fleet.at_fault(f)
  def actuator_pid(%__MODULE__{fleet: f}), do: Fleet.actuator_pid(f)
  def info(%__MODULE__{fleet: f}), do: Fleet.info(f)

  # ---- wire (attacker) -------------------------------------------------------------------------

  @doc "Submit an execute frame over the actuator UDS; normalized reply, observed."
  def submit(%__MODULE__{} = env, effect_bytes, cert_bytes, label \\ nil) do
    frame(env, Wire.execute_frame(effect_bytes, cert_bytes), label)
  end

  @doc "Send an arbitrary frame over the UDS; normalized reply, observed."
  def frame(%__MODULE__{cp: cp} = env, payload, label \\ nil) do
    normalize(env, Wire.uds(cp.actuator_sock, payload), label)
  end

  def status(%__MODULE__{cp: cp} = env, instance_id) do
    normalize(
      env,
      Wire.uds(
        cp.actuator_sock,
        Jason.encode!(%{"op" => "status", "effect_instance_id" => instance_id})
      ),
      nil
    )
  end

  @doc "Record a custom observation label (e.g. a transport-level refusal)."
  def note(%__MODULE__{obs: obs}, label), do: :ets.insert(obs, {:code, to_string(label)})

  def observed(%__MODULE__{obs: obs}),
    do: obs |> :ets.lookup(:code) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  defp normalize(env, {:ok, %{"ok" => true} = m}, label) do
    status = m["status"]
    if status, do: note(env, status)
    _ = label
    %{ok: true, status: status, evidence: m["evidence"], raw: m}
  end

  defp normalize(env, {:ok, %{"ok" => false} = m}, _label) do
    note(env, m["refusal"])
    %{ok: false, stage: m["stage"], refusal: m["refusal"], raw: m}
  end

  defp normalize(env, {:ok, other}, _label) do
    note(env, "unstructured_reply")
    %{ok: false, refusal: "unstructured_reply", raw: other}
  end

  defp normalize(env, {:error, why}, _label) do
    note(env, "transport_closed")
    %{ok: false, transport: why, refusal: "transport_closed"}
  end

  @doc "Actuator ledger entries as the oracle sees them (court/oracle side only)."
  def ledger(%__MODULE__{fleet: f}) do
    C2Harness.Oracle.ledger(Fleet.info(f).state_dir)
  end

  @doc "Wait (bounded) until the actuator answers `health` on the UDS."
  def wait_healthy(%__MODULE__{cp: cp}, tries \\ 100) do
    Enum.reduce_while(1..tries, :timeout, fn _, _ ->
      case Wire.uds(cp.actuator_sock, ~s({"op":"health"}), 1_000) do
        {:ok, %{"ok" => true}} -> {:halt, :ok}
        # SLEEP-CLASS: POLL-STEP (bounded health poll)
        _ -> Process.sleep(50) && {:cont, :timeout}
      end
    end)
  end
end
