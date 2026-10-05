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
  Ask the keymaster (the authority trust domain) for an actuation certificate in the actuator
  wire form. `opts`: `:journal` (default true: an INTENDED issuance recorded in the issuance
  journal; false: a mis-issuance that is not), `:signers` (default `["A","B"]`), `:generation`,
  `:not_before_off`, `:expires_off`, `:policy_epoch`, `:revocation_epoch`, `:audience`,
  `:principal`, `:v`, `:digest`, `:nonces`. Returns `{:ok, %{effect, cert, digest, nonces}}`.
  """
  def issue(%__MODULE__{fleet: f}, effect_map_or_bytes, opts \\ []) do
    eff =
      if is_binary(effect_map_or_bytes), do: effect_map_or_bytes, else: bytes(effect_map_or_bytes)

    req =
      opts
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.merge(%{
        "op" => "issue_actuation",
        "effect" => Base.url_encode64(eff, padding: false)
      })

    case Fleet.km(f, req) do
      {:ok, %{"ok" => true, "certificate" => c, "digest" => d, "nonces" => n}} ->
        {:ok, %{effect: eff, cert: Base.url_decode64!(c, padding: false), digest: d, nonces: n}}

      {:ok, %{"refusal" => code}} ->
        {:error, code}

      other ->
        {:error, other}
    end
  end

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
        _ -> Process.sleep(50) && {:cont, :timeout}
      end
    end)
  end
end
