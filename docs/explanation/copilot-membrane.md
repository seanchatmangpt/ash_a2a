# Copilot Membrane

How the Communicating Digital Twins dispatch membrane is organized: which
module senses, which one deliberates, and where authority enforcement sits.

## The membrane in one sentence

One-sentence ownership test: **if it deliberates or records, it is
ash_pplan; if it senses, communicates, or holds authority, it is ash_a2a.**

This sentence is the canonical boundary law, stated byte-identically in
`ash_pplan/docs/PACKAGE-BOUNDARY.md` ("Boundary Test"). The Copilot
membrane described here is entirely on the sensing/communication/authority
side (`ash_a2a`), and its verdicts are consumed downstream as inputs to
`ash_pplan` deliberation.

## Architecture overview

```
 intent ──► Pipeline.check/3
              │
              ├─► AshA2A.Twin.Vince.evaluate_intent/2      (intent interrogation)
              │     ├─ gpm_floor / monkey_math / round_number_suspicious
              │     └─ mechanical prior via MechanicalPrior behaviour
              ├─► AshA2A.Twin.Tony.handle_inbound/2        (per-coordinator strain gate)
              │     └─ AshA2A.Strain.Tensor.hyperplane_check/2
              ├─► AshA2A.Attestation.Gate                  (sensor-frame attestation)
              └─► Bridge observation feed                  (AshA2A.Strain.Bridge)
```

The pipeline (`AshA2A.Copilot.Pipeline`, `lib/ash_a2a/copilot/pipeline.ex`)
is pure: twins are called via module functions and all state (Vince's
challenge ledger, the Tony mesh, Bridge's mesh_state) is threaded in and out
through the returned `{new_state, result}`. The only environmental read is
the wall clock when the caller does not inject `:now` (disclosed in the
moduledoc); tests inject `:now` for determinism.

## Vince — intent interrogation

`AshA2A.Twin.Vince` (`lib/ash_a2a/twin/vince.ex`) is the adversarial twin.
Every offer is evaluated against mechanical detectors ("Monkey Math") before
any trust is extended:

- **GPM floor** — gross profit margin `gpm/2 = (nte - offer) / nte` below the
  floor (default `0.22`, configurable at `Vince.new/1` via `:gpm_floor`)
  challenges with code `:gpm_floor`, demanding `itemized_cost_breakdown` and
  `subcontractor_quote_doc`. Vocabulary per the `financial-margin-envelope`
  pack (`fme:floor`, law `(NTE - quote)/NTE >= floor`).
- **Monkey-math exact-half** — `exact_half?/3`: the offer is exactly `nte/2`
  within `tolerance` (default 0, absolute on the difference). Challenge code
  `:monkey_math`, demanding `trade_scope_statement` and
  `labor_hours_breakdown`.
- **Round-number suspicion** — `round_suspicious?/2`: the offer is a multiple
  of 100 while the NTE is not. Round numbers on *both* sides are the normal
  quoting pattern and do not flag; only the mismatch pattern flags. Challenge
  code `:round_number_suspicious`, demanding `cost_basis_worksheet`.

Detector order is fixed: repeat-challenge escalation first (a trade already
in the challenge ledger refuses with `:escalate_multisig`), then GPM floor,
then exact-half, then round-number; first firing detector wins
(`Vince.evaluate_intent/2`).

Challenges are **state**: the ledger is a map on the Vince struct
(`challenges`), threaded through the pipeline. A repeat challenge on the same
trade escalates to `{:refuse, :escalate_multisig}`.

Mechanical priors: `AshA2A.Twin.MechanicalPrior` is a one-callback behaviour
(`prior_verdict/2` mapping `{claim, telemetry}` to a typed verdict). The
default `AshA2A.Twin.MechanicalPrior.RefuseAll` stub is an injection point,
not a policy — a real trade domain supplies its own prior via
`Vince.new(prior: MyReticle)` or `Pipeline.check/3`'s `:prior` opt. Trade
reticle packs (generated from `ggen-marketplace` pack
`packs/trade-reticle-plumbing`) implement this behaviour.

## Tony + Strain — load and saturation

`AshA2A.Strain.Tensor` (`lib/ash_a2a/strain/tensor.ex`) is the AHDCLT
cognitive-load tensor: six named dimensions, each typed with a documented
normalization to 0.0–1.0:

| dimension | raw unit | normalization |
|---|---|---|
| `:shift_hours_continuous` | hours into shift | circadian decay `1 - exp(-h / 4.0)` |
| `:active_leases` | lease count | `min(1, count / 12)` |
| `:error_rate` | rolling-window ratio | identity, clamped at 1.0 |
| `:heuristic_frequency` | flagged-event count | `min(1, count / 10)` |
| `:attestation_age_sec` | seconds since attestation | `min(1, age / 3600)` |
| `:financial_risk_exposure` | dollars at risk | `min(1, exposure / 50_000)` |

`hyperplane_check/2` is the **saturation gate**: the weighted sum of
normalized strains (weights 0.30 / 0.25 / 0.20 / 0.10 / 0.05 / 0.10) is
compared against threshold 0.7; above threshold returns
`{:breach, {:saturation_gate, total, threshold}}`.

`AshA2A.Twin.Tony` (`lib/ash_a2a/twin/tony.ex`) is the ergonomic load
balancer over a coordinator mesh. Pure functions over tensor snapshots:

- `Tony.register_coordinator/3` puts an id → tensor snapshot into the mesh.
- `Tony.handle_inbound/2` strain-checks the target coordinator:
  `{:admit, id}` or `{:shed, {:senior_queue, :tony_relief}}`.
- `Tony.triage/2` partitions tickets via the pre-staging checklist
  (`:warranty_status`, `:operating_hours`, `:sla_window`,
  `:contractor_coi_valid`); `Tony.balance/3` diverts high-friction tickets
  (friction > 0.7) from saturated coordinators to the freshest (lowest total
  strain).

`AshA2A.Strain.Bridge` (`lib/ash_a2a/strain/bridge.ex`) folds live
observation events into the tensor. Event → dimension mapping:
`ticket_completed` / `ticket_assigned` step `:active_leases` down/up,
`challenge_received` bumps `:heuristic_frequency`, `error_reported` appends
to the rolling 20-sample error window, `clock_hour` advances the raw shift
clock (the circadian decay lives in `Tensor.strain/2`, not the event).

Fatigue-diversion invariant (Bridge): a coordinator with shift strain > 0.85
AND rising error drift (`error_drift_rising?/2`: recent half of the window
rate > older half) receives no high-friction ticket — diverted to the
freshest coordinator or shed with reason; every ticket ends assigned or
shed-with-reason, none dropped.

## Attestation + Ingress — the five attack classes

`AshA2A.Attestation.Key` (`lib/ash_a2a/attestation/key.ex`) implements
compact ES256 (ECDSA P-256 + SHA-256) signing on the Erlang stdlib `:crypto`
— no JOSE dependency. Token shape: `v1.<base64url(json payload)>.<base64url(der signature)>`.

`AshA2A.Attestation.Gate` (`lib/ash_a2a/attestation/gate.ex`) validates
crypto + claim consistency only. Its moduledoc is explicit about scope: it
does NOT perform true hardware-enclave attestation (that requires
server-side Play Integrity / App Attest / DeviceCheck integration) — it
trusts the signing-key holder and detects only emulators that declare
themselves honestly via claims.

The closed refusal vocabulary is exactly five classes
(`AshA2A.Ingress.Channel` folds the wider gate vocabulary
(`:nonce_mismatch`, `:malformed_token`) into `:spoofed_payload` to keep it
closed):

| class | refused when | detector |
|---|---|---|
| `:bad_signature` | ECDSA verify fails on the `v1.` token | `Key.verify/2` |
| `:stale` | `issued_at` older than `max_staleness_sec` (default 90s), or future timestamp beyond 5s skew | `Gate.verify_freshness/2` |
| `:spoofed_payload` | missing/invalid camera metadata, GPS out of sane bounds, timestamp skew, nonce mismatch, malformed token | `Gate.verify_sensor_metadata/2` |
| `:emulator_detected` | `is_virtual`, emulator fingerprint regex, or known emulator package list hit | `Gate.verify_enclave/2` |
| `:gps_impossible_jump` | > 500 km between consecutive fixes within 60 s (haversine) | `Gate.verify_gps_trajectory/1` |

`AshA2A.Ingress.Channel` (`lib/ash_a2a/ingress/channel.ex`) is the check-in /
telemetry intake surface connecting the gate to event ingress. `ingest/3` is
pure: per-coordinator state (last known GPS fix, refusal counters) is passed
in and returned, never held in a process. On success it normalizes the event
and records the coordinator's last-known fix; on refusal it bumps the
per-reason counter (read via `Channel.stats/1`). Freshness in `ingest/3` is
judged against the `:now` opt passed to the call (wall clock by default), not
the event's own `timestamp` field — so an event carrying a back-dated
timestamp cannot launder a stale token past the gate.

## Copilot.Pipeline — stage order

`AshA2A.Copilot.Pipeline.check/3` runs the interception path:

1. **Vince** — `Vince.evaluate_intent/2` (GPM floor, monkey math, round
   numbers, then the mechanical prior folded in). On challenge: return the
   challenge-as-state ledger entry. On refuse: return refuse.
2. **Mechanical prior** — consulted on the admit path
   (`mechanical_prior/2`, private): `Pipeline.detect_prior/0` resolves the
   application env `:ash_a2a, :copilot_mechanical_prior`, else lane X5's
   `TradeReticle.Plumbing` if loadable, else the stage is skipped (`nil`).
3. **Tony strain gate** — `Tony.handle_inbound/2` (keyed to
   `intent.coordinator_id`; the mesh-level shed is `route/2`'s job).
4. **Attestation** — `Gate.verify_enclave/2` → `verify_freshness/2` →
   `verify_sensor_metadata/2` on `intent.sensor_frame`; a refusal surfaces
   as `{:refuse, %{code: :attestation, reason: refused}}`.

Result shape (typed, no strings-as-state):

```elixir
{:ok, admitted_ticket}
| {:challenge, %{code: _, demanded_evidence: _, retry_token: _}}
| {:refuse, :escalate_multisig | %{code: _, reason: _}}
| {:shed, {:senior_queue, relief_target}}
```

**Strain-vs-Vince order decision** (from the `Copilot.Pipeline` moduledoc):
the moduledoc's rationale is that a saturated coordinator cannot take the
ticket regardless of intent quality, so evaluating Vince first would burn an
expensive interrogation (and mutate its challenge ledger) on a ticket that is
shed anyway. Shedding first protects the human and keeps the Vince ledger
clean of tickets that never had a coordinator. Inside `check/3` the
per-coordinator Tony gate still runs *after* Vince (it is keyed to
`intent.coordinator_id`, which Vince's verdict does not change); the
mesh-level shed decision is `route/2`'s job and happens before Vince by
construction.

Precision note (updated 2026-11-07): `route/2` now exists on
`AshA2A.Copilot.Pipeline` (`lib/ash_a2a/copilot/pipeline.ex:203`) — it
delegates to `AshA2A.Strain.Bridge.route/2` exactly as the moduledoc
describes, so dispatch callers may invoke `Pipeline.route/2` directly before
`check/3` to get the strain-first behavior; calling `Bridge.route/2`
directly remains equivalent.

## Authority.PEP seam — pending wiring

`AshA2A.Authority.PEP` (`lib/ash_a2a/authority/pep.ex`) is a Policy
Enforcement Point seam: `PEP.assert_standing/4` admits or refuses
`{actor_id, scope, context}` against a configured
`AshA2A.Authority.Source` behaviour. The default source is
`AshA2A.Authority.Source.DenyAll` — out of the box the PEP refuses
everything; an allow-source must be configured explicitly
(`Source.AllowAll` exists for tests only).

Its moduledoc carries a wire-point map (documentation only — **no wiring
landed**): `Pipeline.check/3` currently has NO authority hop, and the
prescribed wire point is the top of `check/3`, before any state read or
mutation, returning `{:refused, :insufficient_authority, detail}` on
refusal. Also prescribed: an outer-PEP refusal before
`AshA2A.Agent.build_command/4` for unprincipaled callers, and no
double-gating inside `AshA2A.CommandBus` (it already revalidates against
`admitted_by` immediately before DO).
