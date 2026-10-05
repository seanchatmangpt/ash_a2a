# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Court do
  @moduledoc """
  Orchestrates one C2 compromise court run (RFC-SA2A-006 s26) and returns the report map.

      report = C2Harness.Court.run(n: 20)

  Phases: (1) build the child projects, boot the fleet (keymaster, actuator, authority);
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

  # The real AuthorityService parses effects with effect_class/amount; the Actuator requires an
  # exact key set without them. Recorded, not hidden: this is why actuator-shaped certificates
  # come from the keymaster stand-in in this court.
  defp compat(fleet, cp) do
    alias C2Harness.{Attacker, Wire}
    actuator_effect = Env.effect()
    eb = Env.bytes(actuator_effect)

    to_authority =
      Wire.lp(cp.authority_sock, %{
        "op" => "issue",
        "effect" => Attacker.b64(eb),
        "effect_digest" => Attacker.digest(eb),
        "audience" => "actuator:court",
        "generation" => 1,
        "approvals" => []
      })

    authority_effect = %{
      "effect_class" => "payment",
      "amount" => 1,
      "principal" => "agent:alice",
      "idem" => "x"
    }

    ab = Jcs.encode(authority_effect)
    {:ok, l} = Env.issue(Env.new(fleet, cp, 1), eb, [])

    to_actuator =
      Wire.uds(
        cp.actuator_sock,
        Wire.execute_frame(ab, l.cert)
      )

    [
      %{
        probe: "real AuthorityService given an actuator-shaped PreparedEffect",
        observed: refusal(to_authority),
        standing: if(refusal(to_authority) == "malformed_effect", do: "BLOCKED", else: "UNKNOWN"),
        handoff:
          "AuthorityService.Issuer.parse_effect requires effect_class + amount at the top level; " <>
            "Actuator.Effect requires an exact key set (consequence_class, params...). One side must map " <>
            "consequence_class/params to the policy class and amount before the real authority can " <>
            "issue certificates the actuator accepts (also: authority emits {envelope, message}, actuator " <>
            "wants {..., signatures: [...]}; the same signed message, mechanically convertible)."
      },
      %{
        probe: "Actuator given an authority-shaped effect",
        observed: refusal(to_actuator),
        standing: if(refusal(to_actuator) == "malformed_effect", do: "BLOCKED", else: "UNKNOWN")
      }
    ]
  end

  defp refusal({:ok, %{"refusal" => r}}), do: r
  defp refusal(other), do: inspect(other)

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
          authority: false,
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
