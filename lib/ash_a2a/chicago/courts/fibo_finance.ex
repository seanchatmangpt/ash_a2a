# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.Courts.FiboFinance do
  @moduledoc """
  `CHI-FIN` -- synthetic-finance consequence court over the graphlaw ABI.

  Standing ceiling: finite published corpus passes on exact subject; authority
  NONE; synthetic subject; no general financial safety claim. There is no
  payment rail: the subject is an in-process ETS ledger, the vocabulary is the
  synthetic `fin:` namespace (not FIBO), and the `$10M` figure is this court's
  own grant-ceiling policy, not FIBO's. The court declares `profile :core` and
  no crown gate, so its standing is a court-local verdict, not a crown-gate
  contribution.

  Every semantic question (SHACL envelope and ceiling, SPARQL capability and
  key standing, RDFC canonical seal, `law` plan admission with a `pre_not`
  replay guard) is asked of the real compiled graphlaw JSON ABI. The engine is
  the wasm named by `GRAPHLAW_ABI_WASM`; if it is missing or predates `pre_not`
  every falsifier is `BLOCKED`, never a pass and never a skip. See
  `AshA2A.Chicago.Fixtures.FiboFinance`.

  Falsifiers (each negative has a positive twin, and the test suite removes
  each negative's guard to prove it survives without it):

    * `CHI-FIN-001` `$25M` against a `$9M` `money_micros` envelope refuses
    * `CHI-FIN-002` positive control: `$5M` inside the envelope completes
    * `CHI-FIN-003` valid semantics + signature + capability + plan, but a `$10M`
      grant ceiling => DO refused
    * `CHI-FIN-004` positive control: exactly `$10M` at the `$10M` ceiling completes
    * `CHI-FIN-005` exact `$100M` authority whose counterparty is mutated after
      the effect was sealed refuses
    * `CHI-FIN-006` positive control: the same exact authority, intact, completes
    * `CHI-FIN-007` a revoked signing key refuses
    * `CHI-FIN-008` a replayed receipt yields no second debit (`pre_not settled`)
    * `CHI-FIN-009` processor claims success, independent ledger observer
      disagrees => completed standing withheld
    * `CHI-FIN-010` positive control: observer agrees => completed
    * `CHI-FIN-011` crash after DO, before receipt => reconciled, not re-executed
    * `CHI-FIN-012` a cascade stops at the depth bound
    * `CHI-FIN-013` positive control: a cascade inside the bound runs to chain end
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.FiboFinance, as: Fx
  alias AshA2A.Chicago.Fixtures.FiboFinance.Abi

  @court "CHI-FIN"
  @sections ["§10", "§39", "§68", "§70", "§73", "§100"]

  @impl true
  def id, do: @court
  @impl true
  def title,
    do:
      "Synthetic finance: envelope, ceiling, seal, key standing, replay, observer, crash, cascade"

  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: @sections
  @impl true
  def ocel_mappings, do: Fx.mappings()

  # --- predicates --------------------------------------------------------------------

  defp submitted(amount), do: {:observed, "fin.submit", %{"amount_micros" => to_string(amount)}}
  defp effect_reached, do: {:observed, "fin.do", %{"outcome" => "processed"}}
  defp completed, do: {:observed, "fin.receipt", %{"status" => "completed"}}
  defp upstream_ok, do: {:observed, "fin.gate", %{"gate" => "plan", "outcome" => "ok"}}

  @impl true
  def falsifiers do
    [
      neg(1,
        invariant:
          "A transfer above the money_micros envelope never reaches the effect (SHACL sh:maxInclusive over the graphlaw ABI)",
        stimulus:
          "submit a $25M (25_000_000_000_000 micros) signed transfer against a $9M envelope",
        boundary: "graphlaw ABI shacl op, gate `envelope`, before any effect",
        forbidden_outcome: "the processor is invoked (a debit is written) for the $25M transfer",
        attempt_evidence: "fin.submit amount_micros=25000000000000 for the stimulus",
        survival_evidence:
          "fin.do outcome=processed in OCEL; the court's ledger scan finds a row",
        guard: "Fixtures.FiboFinance envelope gate (SHACL sh:maxInclusive env.envelope)",
        failure_class: :bound_failure,
        attempt_predicate: submitted(Fx.usd(25)),
        outcome_predicate: effect_reached(),
        tags: [:envelope]
      ),
      pos(2,
        invariant:
          "A transfer inside the envelope, validly signed and granted, completes (control for 001)",
        stimulus: "submit a $5M signed transfer against the same $9M envelope",
        boundary: "the full pipeline to receipt",
        attempt_evidence: "fin.submit amount_micros=5000000000000",
        survival_evidence:
          "fin.do processed and fin.receipt completed; the court's ledger scan finds exactly one row",
        failure_class: :bound_failure,
        attempt_predicate: submitted(Fx.usd(5)),
        outcome_predicate: {:all, [effect_reached(), completed()]}
      ),
      neg(3,
        invariant:
          "Valid semantics, signature, capability and plan do not authorise an amount above the grant ceiling: the DO is refused",
        stimulus:
          "submit a $25M transfer under a $10M grant ceiling (envelope open, key active, plan admitted)",
        boundary: "graphlaw ABI shacl op, gate `ceiling`, at the DO boundary",
        forbidden_outcome: "the processor is invoked for a transfer above the grant ceiling",
        attempt_evidence:
          "fin.submit amount_micros=25000000000000 AND fin.gate plan outcome=ok (every earlier gate passed)",
        survival_evidence:
          "fin.do outcome=processed in OCEL; the court's ledger scan finds a row",
        guard:
          "Fixtures.FiboFinance ceiling gate (SHACL sh:lessThanOrEquals fin:grantCeilingMicros; a monetary fact, not a graphlaw lease Ceiling)",
        failure_class: :authority_failure,
        attempt_predicate: {:all, [submitted(Fx.usd(25)), upstream_ok()]},
        outcome_predicate: effect_reached(),
        tags: [:ceiling]
      ),
      pos(4,
        invariant:
          "A transfer exactly at the grant ceiling completes: the ceiling is inclusive (control for 003)",
        stimulus: "submit a $10M transfer under a $10M grant ceiling",
        boundary: "the full pipeline to receipt",
        attempt_evidence: "fin.submit amount_micros=10000000000000",
        survival_evidence: "fin.do processed and fin.receipt completed; one ledger row",
        failure_class: :authority_failure,
        attempt_predicate: submitted(Fx.usd(10)),
        outcome_predicate: {:all, [effect_reached(), completed()]}
      ),
      neg(5,
        invariant:
          "An exact $100M authority is bound to the sealed effect: a counterparty mutated after sealing never reaches the effect",
        stimulus:
          "seal a $100M transfer (canonical id), swap the counterparty, then reach the DO boundary",
        boundary: "graphlaw ABI canonical op re-derived at the DO boundary, gate `seal`",
        forbidden_outcome: "the processor is invoked for the mutated effect",
        attempt_evidence:
          "fin.submit amount_micros=100000000000000 AND fin.mutation field=counterparty",
        survival_evidence:
          "fin.do outcome=processed in OCEL; a ledger row names the mutated counterparty",
        guard: "Fixtures.FiboFinance seal gate (canonical id of the effect at DO == sealed id)",
        failure_class: :authority_failure,
        attempt_predicate:
          {:all,
           [submitted(Fx.usd(100)), {:observed, "fin.mutation", %{"field" => "counterparty"}}]},
        outcome_predicate: effect_reached(),
        tags: [:seal]
      ),
      pos(6,
        invariant:
          "The same exact $100M authority with the sealed counterparty intact completes (control for 005)",
        stimulus: "submit and execute the $100M transfer with no mutation",
        boundary: "the full pipeline to receipt",
        attempt_evidence: "fin.submit amount_micros=100000000000000",
        survival_evidence: "fin.do processed, fin.receipt completed, and no fin.mutation",
        failure_class: :authority_failure,
        attempt_predicate: submitted(Fx.usd(100)),
        outcome_predicate:
          {:all, [effect_reached(), completed(), {:not_observed, "fin.mutation"}]}
      ),
      neg(7,
        invariant:
          "A cryptographically valid signature by a revoked key never reaches the effect",
        stimulus:
          "submit a $5M transfer signed by the revoked key (signature verifies, registry says Revoked)",
        boundary: "graphlaw ABI sparql op over the key registry, gate `key_status`",
        forbidden_outcome: "the processor is invoked for a revoked key's transfer",
        attempt_evidence:
          "fin.submit key_id=urn:key:revoked AND fin.gate signature outcome=ok (the signature really verified)",
        survival_evidence:
          "fin.do outcome=processed in OCEL; the court's ledger scan finds a row",
        guard: "Fixtures.FiboFinance key_status gate (ASK <key> fin:status fin:Active)",
        failure_class: :authority_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "fin.submit", %{"key_id" => Fx.revoked_key()}},
             {:observed, "fin.gate", %{"gate" => "signature", "outcome" => "ok"}}
           ]},
        outcome_predicate: effect_reached(),
        tags: [:key_standing]
      ),
      neg(8,
        invariant:
          "A replayed receipt's transaction yields no second debit: the plan's pre_not (settled) refuses it",
        stimulus: "submit a completed $5M transaction a second time",
        boundary: "graphlaw ABI law op, plan step with pre_not `fin:settled`, gate `plan`",
        forbidden_outcome: "the processor is invoked twice for one transaction",
        attempt_evidence: "two fin.submit events and a first fin.receipt status=completed",
        survival_evidence: "two fin.do events in OCEL; the court's ledger scan finds two rows",
        guard:
          "Fixtures.FiboFinance plan gate pre_not `<tx> fin:settled \"true\"` (graphlaw Plan::admit)",
        failure_class: :replay_failure,
        attempt_predicate: {:all, [{:count, "fin.submit", :eq, 2}, completed()]},
        outcome_predicate: {:count, "fin.do", :gte, 2},
        tags: [:replay]
      ),
      neg(9,
        invariant:
          "A processor's own success claim never yields completed standing when the independent ledger observer disagrees",
        stimulus: "a lying processor returns success for a $5M transfer and writes nothing",
        boundary: "the independent full-scan ledger observer versus the processor's claim",
        forbidden_outcome: "fin.receipt status=completed for a transfer with no ledger row",
        attempt_evidence:
          "fin.do processor=lying AND fin.observe ledger_rows=0 (the ledger really has no row)",
        survival_evidence:
          "fin.receipt status=completed in OCEL; the court's own receipt read-back",
        guard:
          "Fixtures.FiboFinance observe_and_receipt (claim vs ledger rows; withheld unless they agree)",
        failure_class: :postcondition_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "fin.do", %{"processor" => "lying"}},
             {:observed, "fin.observe", %{"ledger_rows" => "0"}}
           ]},
        outcome_predicate: completed(),
        tags: [:observer]
      ),
      pos(10,
        invariant:
          "An honest processor whose effect the observer independently reads keeps completed standing (control for 009)",
        stimulus: "an honest processor debits $5M",
        boundary: "the independent full-scan ledger observer",
        attempt_evidence: "fin.do processor=honest",
        survival_evidence:
          "fin.observe agrees=true independent=true ledger_rows=1 and fin.receipt completed",
        failure_class: :postcondition_failure,
        attempt_predicate: {:observed, "fin.do", %{"processor" => "honest"}},
        outcome_predicate:
          {:all,
           [
             {:observed, "fin.observe",
              %{"agrees" => "true", "independent" => "true", "ledger_rows" => "1"}},
             completed()
           ]}
      ),
      neg(11,
        invariant:
          "A crash after the effect and before the receipt is reconciled against the ledger, never re-executed",
        stimulus:
          "kill the executing process after the debit and before the receipt, then run recovery over the journal",
        boundary: "the intent journal and the independent ledger read before any re-execution",
        forbidden_outcome: "a second fin.do (the effect is applied twice)",
        attempt_evidence:
          "fin.do then fin.crash for the same transaction (a real :kill), no fin.receipt before recovery",
        survival_evidence: "two fin.do events in OCEL; the court's ledger scan finds two rows",
        guard:
          "Fixtures.FiboFinance.recover/2 (read the ledger; reconcile when the effect is present)",
        failure_class: :replay_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, "fin.do"},
             {:observed, "fin.crash", %{"point" => "after_do_before_receipt"}},
             {:precedes, "fin.do", "fin.crash", "fin_transaction"}
           ]},
        outcome_predicate: {:count, "fin.do", :gte, 2},
        tags: [:crash]
      ),
      neg(12,
        invariant:
          "A cascade in which every completed hop triggers another stops at the depth bound",
        stimulus: "demand a 10-hop cascade of $1M transfers under a depth bound of 3",
        boundary: "the cascade loop's depth bound",
        forbidden_outcome: "more than 3 hops execute",
        attempt_evidence: "fin.cascade.hop depth=1 (the cascade started)",
        survival_evidence: "4 or more fin.cascade.hop events in OCEL; more than 3 ledger rows",
        guard: "Fixtures.FiboFinance cascade_loop depth bound",
        failure_class: :bound_failure,
        attempt_predicate: {:observed, "fin.cascade.hop", %{"depth" => "1"}},
        outcome_predicate: {:count, "fin.cascade.hop", :gte, 4},
        tags: [:cascade]
      ),
      pos(13,
        invariant:
          "A cascade that ends inside the bound runs to its natural end (control for 012)",
        stimulus: "demand a 3-hop cascade of $1M transfers under a depth bound of 3",
        boundary: "the cascade loop",
        attempt_evidence: "fin.cascade.hop depth=1",
        survival_evidence:
          "exactly 3 fin.cascade.hop events and fin.cascade.stop reason=chain_end",
        failure_class: :bound_failure,
        attempt_predicate: {:observed, "fin.cascade.hop", %{"depth" => "1"}},
        outcome_predicate:
          {:all,
           [
             {:count, "fin.cascade.hop", :eq, 3},
             {:observed, "fin.cascade.stop", %{"reason" => "chain_end"}}
           ]}
      )
    ]
  end

  defp neg(n, fields), do: build(n, :negative, fields)
  defp pos(n, fields), do: build(n, :positive_control, fields)

  defp build(n, kind, fields) do
    Falsifier.new!(
      [
        id: "CHI-FIN-" <> String.pad_leading(Integer.to_string(n), 3, "0"),
        court_id: @court,
        kind: kind,
        rfc_sections: @sections
      ] ++
        fields
    )
  end

  # --- run -----------------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = falsifiers()

    case Fx.start_abi() do
      {:blocked, reason} ->
        Enum.map(fs, &Result.blocked(&1, "BLOCKED[wasm-artifact]: " <> reason))

      {:ok, abi} ->
        try do
          sha = Abi.sha256(abi)
          fs |> Enum.map(&verdict(&1, ctx, abi, sha))
        after
          Abi.stop(abi)
        end
    end
  end

  defp verdict(f, ctx, abi, sha) do
    n = f.id |> String.slice(-3, 3) |> String.to_integer()
    {result, s} = scenario(n, f, ctx, abi)
    %{result | evidence: Map.merge(result.evidence, evidence(s, sha))}
  end

  defp scenario(1, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.envelope_breach(abi) end)

    {Result.negative(f,
       attempt_observed?:
         seen?(ctx, f, "fin.submit", %{"amount_micros" => "#{Fx.usd(25)}"}) and
           s.amount > s.envelope,
       forbidden_outcome_observed?: s.rows != []
     ), s}
  end

  defp scenario(2, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.within_envelope(abi) end)
    {control(f, ctx, s, Fx.usd(5)), s}
  end

  defp scenario(3, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.ceiling_breach(abi) end)

    {Result.negative(f,
       attempt_observed?:
         seen?(ctx, f, "fin.submit", %{"amount_micros" => "#{Fx.usd(25)}"}) and
           seen?(ctx, f, "fin.gate", %{"gate" => "plan", "outcome" => "ok"}) and
           s.amount > s.ceiling,
       forbidden_outcome_observed?: s.rows != []
     ), s}
  end

  defp scenario(4, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.ceiling_boundary(abi) end)
    {control(f, ctx, s, Fx.usd(10)), s}
  end

  defp scenario(5, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.counterparty_mutation(abi) end)

    {Result.negative(f,
       attempt_observed?:
         seen?(ctx, f, "fin.mutation", %{"field" => "counterparty"}) and
           seen?(ctx, f, "fin.submit", %{"amount_micros" => "#{Fx.usd(100)}"}),
       forbidden_outcome_observed?: s.rows != []
     ), s}
  end

  defp scenario(6, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.exact_authority(abi) end)
    {control(f, ctx, s, Fx.usd(100)), s}
  end

  defp scenario(7, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.revoked_key_submission(abi) end)

    {Result.negative(f,
       attempt_observed?:
         seen?(ctx, f, "fin.submit", %{"key_id" => Fx.revoked_key()}) and
           seen?(ctx, f, "fin.gate", %{"gate" => "signature", "outcome" => "ok"}),
       forbidden_outcome_observed?: s.rows != []
     ), s}
  end

  defp scenario(8, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.replay(abi) end)

    submits = ctx |> Context.observed(f) |> Enum.count(&(&1.activity == "fin.submit"))

    {Result.negative(f,
       attempt_observed?: submits == 2 and match?([%{outcome: :completed} | _], s.results),
       forbidden_outcome_observed?: length(s.rows) >= 2
     ), s}
  end

  defp scenario(9, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.lying_processor(abi) end)

    {Result.negative(f,
       attempt_observed?:
         seen?(ctx, f, "fin.do", %{"processor" => "lying"}) and
           seen?(ctx, f, "fin.observe", %{"ledger_rows" => "0"}) and s.rows == [],
       forbidden_outcome_observed?: match?([%{outcome: :completed}], s.results)
     ), s}
  end

  defp scenario(10, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.honest_processor(abi) end)

    {Result.positive(f,
       attempt_observed?: seen?(ctx, f, "fin.do", %{"processor" => "honest"}),
       expected_outcome_observed?:
         match?([%{outcome: :completed, observed_rows: 1}], s.results) and length(s.rows) == 1 and
           seen?(ctx, f, "fin.observe", %{"agrees" => "true", "independent" => "true"})
     ), s}
  end

  defp scenario(11, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.crash_after_do(abi) end)

    {Result.negative(f,
       attempt_observed?:
         match?([%{outcome: :crashed}], s.results) and seen?(ctx, f, "fin.crash", %{}) and
           seen?(ctx, f, "fin.do", %{"outcome" => "processed"}),
       forbidden_outcome_observed?:
         length(s.rows) > 1 or s.recovered == [] or
           Enum.any?(s.recovered, &(&1.outcome != :reconciled))
     ), s}
  end

  defp scenario(12, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.cascade(abi, 10) end)

    {Result.negative(f,
       attempt_observed?: seen?(ctx, f, "fin.cascade.hop", %{"depth" => "1"}),
       forbidden_outcome_observed?: length(s.rows) > s.depth_bound
     ), s}
  end

  defp scenario(13, f, ctx, abi) do
    s = Context.stimulus(ctx, f, fn -> Fx.cascade(abi, 3) end)

    {Result.positive(f,
       attempt_observed?: seen?(ctx, f, "fin.cascade.hop", %{"depth" => "1"}),
       expected_outcome_observed?: length(s.rows) == 3 and s.stop == "chain_end"
     ), s}
  end

  defp control(f, ctx, s, amount) do
    Result.positive(f,
      attempt_observed?: seen?(ctx, f, "fin.submit", %{"amount_micros" => "#{amount}"}),
      expected_outcome_observed?:
        match?([%{outcome: :completed}], s.results) and
          match?([%{amount: ^amount}], s.rows)
    )
  end

  # --- readers / evidence ---------------------------------------------------------------

  defp seen?(ctx, f, activity, attrs) do
    ctx
    |> Context.observed(f)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == v end)
    end)
  end

  defp evidence(s, sha) do
    %{
      "graphlaw_abi_wasm_sha256" => sha,
      "outcomes" => Enum.map(s.results, &outcome/1),
      "ledger_rows" => length(s.rows),
      "ledger_total_micros" => s.rows |> Enum.map(& &1.amount) |> Enum.sum(),
      "counterparties" => s.rows |> Enum.map(& &1.counterparty) |> Enum.sort(),
      "recovered" => Enum.map(Map.get(s, :recovered, []), &inspect/1),
      "standing_ceiling" =>
        "finite published corpus passes on exact subject; authority NONE; synthetic subject; no general financial safety claim"
    }
  end

  defp outcome(%{outcome: o}), do: inspect(o)
end
