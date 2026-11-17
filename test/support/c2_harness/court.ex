# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Court do
  @moduledoc """
  Orchestrates one C2 compromise court run (RFC-SA2A-006 s26) and returns the report map.

      report = C2Harness.Court.run(n: 20)

  Phases: (1) build the child projects, boot the fleet (keymaster, actuator, two authorities);
  (2) prove the control-plane environment holds no protected key material; (3) compat
  probes (recorded integration handoffs); (4) run the attack catalog against the stock
  actuator and the real authority; (5) MUTATION court: for every fence check a fresh fleet
  whose actuator has exactly that check force-skipped, run the attacks that check exists
  to stop and require at least one to FAIL the ledger oracle; plus the unfenced
  "always allow" actuator (every check skipped), which must fail the whole court.
  """
  alias C2Harness.{
    Attack,
    AuthorityAttacks,
    Catalog,
    Entrypoint,
    Env,
    Faults,
    Fleet,
    Report,
    Runner,
    Scan
  }

  @max_n 50

  @doc """
  Options: `:n` fault-injection repetitions (default 20, at most 50; env `C2_COURT_N`),
  `:mutant_n` repetitions inside mutant fleets (default 3), `:mutation` (default true),
  `:only` (list of attack ids), `:build_root`.
  """
  def run(opts \\ []) do
    n = opts |> Keyword.get(:n, env_int("C2_COURT_N", 20)) |> max(1) |> min(@max_n)
    mutant_n = Keyword.get(opts, :mutant_n, env_int("C2_COURT_MUTANT_N", 3))
    build_root = Keyword.get(opts, :build_root, Fleet.default_build_root())
    t0 = System.monotonic_time(:millisecond)
    :ok = Fleet.ensure_built(build_root)

    {:ok, fleet} = Fleet.start_link(build_root: build_root, skip_build: true, authority: true)
    cp = Fleet.control_plane(fleet)

    try do
      scan = Scan.control_plane(fleet, cp)
      compat = compat(fleet, cp)
      attacks = select(catalog(), opts[:only])
      results = Enum.map(attacks, &run_one(&1, fleet, cp, n))
      entry = Enum.map(select(Entrypoint.attacks(), opts[:only]), &run_one(&1, fleet, cp, n))

      mutation =
        if Keyword.get(opts, :mutation, true),
          do: mutation(catalog(), build_root, mutant_n, opts[:only]),
          else: %{skipped: true}

      Report.build(%{
        n: n,
        mutant_n: mutant_n,
        results: results ++ entry,
        scan: scan,
        compat: compat,
        mutation: mutation,
        duration_ms: System.monotonic_time(:millisecond) - t0,
        info: Fleet.info(fleet)
      })
    after
      Fleet.stop(fleet)
    end
  end

  def catalog, do: Catalog.actuator_attacks() ++ Faults.attacks() ++ AuthorityAttacks.attacks()

  def run_one(%Attack{} = a, fleet, cp, n, opts \\ []) do
    env = Env.new(fleet, cp, n)
    Runner.run(a, env, opts)
  end

  defp select(attacks, nil), do: attacks
  defp select(attacks, ids), do: Enum.filter(attacks, &(&1.id in ids))

  # ---- compat probes -------------------------------------------------------------------------------------

  # Each probe records what the two REAL services did with each other's artifacts:
  #   1. the pure release path: real AuthorityService (prod build) issues for an
  #      actuator-shaped effect, `Issuer.to_actuator_certificate/1` converts it, and the real
  #      actuator (prod entrypoint, registry = the authority's key only, quorum 1) executes it.
  #      No keymaster signature is involved.
  #   2. the same certificate at the COURT actuator, which pins quorum 2: one custodian is not
  #      enough, by policy.
  #   3. the court path every intended issuance uses: two independent real authorities (two
  #      keys, two custodians), signatures combined with `Issuer.combine_actuator_certificates/1`;
  #      no keymaster signature.
  #   4. an authority-shaped effect at the actuator: refused by design (exact key set).
  defp compat(fleet, cp) do
    alias C2Harness.{Attacker, Wire}
    env = Env.new(fleet, cp, 1)

    real_cert = fn eb ->
      d = Attacker.digest(eb)
      approvals = for n <- ["bob", "carol"], do: Env.approve(env, n, d, generation: 1)

      issued =
        Wire.lp(cp.authority_sock, %{
          "op" => "issue",
          "effect" => Attacker.b64(eb),
          "effect_digest" => d,
          "audience" => cp.audience,
          "generation" => 1,
          "approvals" => approvals
        })

      with {:ok, %{"ok" => true, "certificate" => cert}} <- issued,
           {:ok, %{"ok" => true, "certificate" => c}} <-
             Fleet.km(fleet, %{"op" => "convert_actuation", "certificate" => cert}) do
        {:ok, Base.url_decode64!(c, padding: false)}
      end
    end

    outcome = fn
      {:ok, %{"ok" => true, "status" => s}} -> s
      {:ok, %{"refusal" => r}} -> r
      other -> inspect(other)
    end

    # 2: real authority certificate alone at the quorum-2 court actuator
    eb2 = Env.bytes(Env.effect())
    {:ok, cert2} = real_cert.(eb2)
    alone = outcome.(Wire.uds(cp.actuator_sock, Wire.execute_frame(eb2, cert2)))

    # 3: the court's intended-issuance path
    l3 = Env.issue!(env, Env.effect())
    cosigned = outcome.(Wire.uds(cp.actuator_sock, Wire.execute_frame(l3.effect, l3.cert)))

    # 4: authority-shaped effect at the actuator
    ab =
      Jcs.encode(%{
        "effect_class" => "payment",
        "amount" => 1,
        "principal" => "agent:alice",
        "idem" => "x"
      })

    shaped = outcome.(Wire.uds(cp.actuator_sock, Wire.execute_frame(ab, l3.cert)))

    # 1: pure release path (replaces the court actuator for the probe, then restores it)
    eb1 = Env.bytes(Env.effect())
    {:ok, cert1} = real_cert.(eb1)
    {:ok, _pid, alt_state} = Fleet.start_prod_actuator(fleet, authority_only: true)
    :ok = Env.wait_healthy(env)
    pure = outcome.(Wire.uds(cp.actuator_sock, Wire.execute_frame(eb1, cert1)))
    replay = outcome.(Wire.uds(cp.actuator_sock, Wire.execute_frame(eb1, cert1)))

    pure_ledger =
      case C2Harness.Oracle.ledger(alt_state) do
        {:ok, es} -> Enum.count(es, &(&1["effect_digest"] == Attacker.digest(eb1)))
        {:error, why, _} -> inspect(why)
      end

    :ok = Fleet.start_actuator(fleet, [])
    :ok = Env.wait_healthy(env)

    standing = fn observed, want, yes, no -> if observed == want, do: yes, else: no end

    [
      %{
        probe:
          "real AuthorityService certificate for an actuator-shaped effect, converted with " <>
            "Issuer.to_actuator_certificate/1, executed by the real actuator (prod entrypoint, " <>
            "registry = authority key only, quorum 1)",
        observed: pure,
        replay_observed: replay,
        ledger_entries_for_effect: pure_ledger,
        standing:
          if(pure == "performed" and replay == "replayed" and pure_ledger == 1,
            do: "ACCEPTED",
            else: "BLOCKED"
          )
      },
      %{
        probe:
          "the same kind of certificate (one custodian: the authority) at the court actuator, " <>
            "which pins quorum 2",
        observed: alone,
        standing: standing.(alone, "quorum_not_met", "REFUSED_BY_POLICY", "UNEXPECTED")
      },
      %{
        probe:
          "court issuance path: certificates from two independent real AuthorityService " <>
            "instances combined with Issuer.combine_actuator_certificates/1 (two custodians, " <>
            "no keymaster signature), executed by the court actuator (quorum 2)",
        observed: cosigned,
        standing: standing.(cosigned, "performed", "ACCEPTED", "BLOCKED")
      },
      %{
        probe: "Actuator given an authority-shaped effect (effect_class + amount)",
        observed: shaped,
        standing: standing.(shaped, "malformed_effect", "REFUSED_BY_DESIGN", "UNEXPECTED")
      }
    ]
  end

  # ---- mutation court ---------------------------------------------------------------------------------------

  @doc false
  def mutation(catalog, build_root, mutant_n, only) do
    by_check =
      for check <- 1..16,
          killers = for(a <- catalog, check in a.killers_for, do: a),
          killers != [],
          into: %{},
          do: {check, killers}

    entries =
      for {check, killers} <- Enum.sort(by_check),
          do: mutant(check, [check], killers, build_root, mutant_n, only)

    # check 10 has no attack that isolates it: a presented-but-invalid signature is also not
    # counted by check 11, so 10 alone is strictness. Evidence: {10} survives, {10,11} dies.
    sig_attacks =
      Enum.filter(
        catalog,
        &(&1.id in ["C2C-A02", "C2C-A03", "C2C-A34", "C2C-A38", "C2C-A20", "C2C-A21"])
      )

    ten_alone = mutant(10, [10], sig_attacks, build_root, mutant_n, only)
    ten_eleven = mutant(10, [10, 11], sig_attacks, build_root, mutant_n, only)

    all_attacks = Enum.filter(catalog, &(&1.scope == :actuator))
    allow_all = mutant(:all, :all, all_attacks, build_root, min(mutant_n, 2), only)

    %{
      per_check: entries,
      check_10_alone: ten_alone,
      check_10_and_11: ten_eleven,
      allow_all: allow_all
    }
  end

  defp mutant(label, skip, killers, build_root, n, only) do
    killers = select(killers, only)

    if killers == [] do
      %{check: label, skip: skip, status: :no_killers_selected, killers: []}
    else
      {:ok, fleet} =
        Fleet.start_link(
          build_root: build_root,
          skip_build: true,
          authority: true,
          mutant_skip: skip
        )

      cp = Fleet.control_plane(fleet)

      try do
        results = Enum.map(killers, &run_one(&1, fleet, cp, n, vacuity: false))
        killed = Enum.filter(results, &(&1.verdict == :fail))
        errors = Enum.filter(results, &(&1.verdict == :error))

        %{
          check: label,
          skip: skip,
          status: if(killed != [], do: :killed, else: :survived),
          killed_by: Enum.map(killed, & &1.id),
          killers:
            Enum.map(
              results,
              &Map.take(&1, [:id, :verdict, :reasons, :ledger_diff, :refusal_codes])
            ),
          errors: Enum.map(errors, & &1.id)
        }
      after
        Fleet.stop(fleet)
      end
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      v -> String.to_integer(v)
    end
  end
end
