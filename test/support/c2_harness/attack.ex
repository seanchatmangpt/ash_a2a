defmodule C2Harness.Attack do
  @moduledoc """
  One court attack: metadata for the report plus a `run` function executed against a live
  fleet. `run` returns `%{authorized: [digest], authority_authorized: [{digest, gen}],
  notes: [term], iterations: n}` describing what the authority's journal legitimately
  authorizes for this attack. It never decides the verdict: `C2Harness.Runner` does, from
  the ledger.

    * `checks`: actuator fence checks (1..16) the attack is designed to reach
    * `killers_for`: fence checks whose removal this attack must expose (mutation court)
    * `expect`: refusal codes / statuses that must ALL be observed (anti-vacuity: proves the
      attack reached its target, so a refusal for the wrong reason is `:vacuous`)
    * `expect_any`: at least one of these must be observed
    * `scope`: `:actuator` (oracle = effect ledger) or `:authority` (oracle = real
      AuthorityService issuance journal; the ledger must additionally stay unchanged)
    * `faults`: true when the attack repeats N times with process kills
    * `mapping`: `%{attck: [...], capec: [...], atlas: [...]}` (court-assigned; see
      docs/reference/c2-compromise-court.md for the provenance and its limits)
  """
  @enforce_keys [:id, :title, :s26, :run]
  defstruct [
    :id,
    :title,
    :s26,
    :run,
    scope: :actuator,
    checks: [],
    killers_for: [],
    expect: [],
    expect_any: [],
    faults: false,
    mapping: %{attck: [], capec: [], atlas: []}
  ]

  @type t :: %__MODULE__{}
end

defmodule C2Harness.Runner do
  @moduledoc """
  Runs one attack and computes its verdict from the oracle:

    * `:pass`    oracle rule holds AND the attack observed what it says it targets
    * `:fail`    the oracle rule is violated (an unauthorized or duplicated consequence, a
                 rewritten/broken ledger, an unauthorized or duplicated issuance)
    * `:vacuous` oracle rule holds but a required refusal code was never observed (the
                 attack did not reach its target): counts as a court failure
    * `:error`   the attack script raised or the oracle could not be read: counts as a court
                 failure (an exception is never a pass)
  """
  alias C2Harness.{Attack, Env, Fleet, Oracle}

  @spec run(Attack.t(), Env.t(), keyword()) :: map()
  def run(%Attack{} = a, %Env{} = env, opts \\ []) do
    check_vacuity? = Keyword.get(opts, :vacuity, true)
    info = Fleet.info(env.fleet)
    :ok = Fleet.write_revocation(env.fleet, %{})
    {before_l, before_j} = snapshot(info)
    t0 = System.monotonic_time(:millisecond)

    outcome =
      try do
        {:ok,
         Map.merge(
           %{authorized: [], authority_authorized: [], notes: [], iterations: 1},
           a.run.(env)
         )}
      rescue
        e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    ensure_actuator(env)
    :ok = Fleet.write_revocation(env.fleet, %{})
    {after_l, after_j} = snapshot(info)
    issuance = issuance(info)

    ran = match?({:ok, _}, outcome)
    res = elem(outcome, 1)
    authorized = if ran, do: res.authorized, else: []
    authority_authorized = if ran, do: res.authority_authorized, else: []

    {verdict, reasons, diff} =
      verdict(a, before_l, after_l, before_j, after_j, authorized, authority_authorized, issuance)

    observed = Env.observed(env)

    missing = if check_vacuity?, do: missing_codes(a, observed), else: []

    {final, reasons} =
      cond do
        not ran -> {:error, [{:attack_raised, res}]}
        verdict == :fail -> {:fail, reasons}
        missing != [] -> {:vacuous, [{:never_observed, missing}]}
        true -> {:pass, []}
      end

    %{
      id: a.id,
      title: a.title,
      s26: a.s26,
      scope: a.scope,
      checks: a.checks,
      killers_for: a.killers_for,
      mapping: a.mapping,
      verdict: final,
      reasons: reasons,
      refusal_codes: observed,
      expected: a.expect,
      expected_any: a.expect_any,
      ledger_before: length(before_l),
      ledger_after: length(after_l),
      ledger_diff:
        Enum.map(diff, &Map.take(&1, ["seq", "effect_instance_id", "effect_digest", "hash"])),
      authority_journal_before: length(before_j),
      authority_journal_after: length(after_j),
      authorized: authorized,
      notes: if(ran, do: res.notes, else: []),
      iterations: if(ran, do: res.iterations, else: 0),
      duration_ms: System.monotonic_time(:millisecond) - t0
    }
  end

  defp missing_codes(a, observed) do
    all = Enum.reject(a.expect, &(&1 in observed))

    any =
      if a.expect_any == [] or Enum.any?(a.expect_any, &(&1 in observed)),
        do: [],
        else: [a.expect_any]

    all ++ any
  end

  defp snapshot(info) do
    l =
      case Oracle.ledger(info.state_dir) do
        {:ok, e} -> e
        {:error, _, e} -> e
      end

    j =
      case Oracle.journal(info.auth_journal) do
        {:ok, b} -> b
        {:error, _, b} -> b
      end

    {l, j}
  end

  defp issuance(info) do
    case Oracle.journal(Path.join(info.dirs["km"], "issuance_journal.log")) do
      {:ok, b} -> b
      {:error, _, b} -> b
    end
  end

  defp verdict(%Attack{scope: :authority}, bl, al, bj, aj, _auth, auth_pairs, _iss) do
    ledger_unchanged =
      if bl == al,
        do: [],
        else: [{:actuator_ledger_changed_by_authority_attack, length(al) - length(bl)}]

    case Oracle.authority_verdict(bj, aj, auth_pairs) do
      {:pass, d} when ledger_unchanged == [] -> {:pass, [], d}
      {:pass, d} -> {:fail, ledger_unchanged, d}
      {:fail, r, d} -> {:fail, r ++ ledger_unchanged, d}
    end
  end

  defp verdict(%Attack{}, bl, al, _bj, _aj, authorized, _pairs, issuance) do
    case Oracle.verdict(bl, al, authorized, issuance) do
      {:pass, d} -> {:pass, [], d}
      {:fail, r, d} -> {:fail, r, d}
    end
  end

  defp ensure_actuator(env) do
    unless Fleet.actuator_alive?(env.fleet) do
      Fleet.start_actuator(env.fleet, [])
    end

    Env.wait_healthy(env)
  end
end
