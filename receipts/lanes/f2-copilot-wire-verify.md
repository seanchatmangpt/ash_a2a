# F2 — Copilot Pipeline Wire-Verify (closing G4+G5 stopped work)

Standing: PASS

Repo: /Users/sac/ash_a2a (no git commands run, per lane contract)

## Gate

`MIX_BUILD_ROOT=_build-laneF2 mix test test/copilot/ test/attention/ test/authority/`

- Run 1: COMPILE ABORT — `lib/ash_a2a/ingress/channel.ex:167` called
  `bind_field?/3`; only 2-arity clauses existed (shared-file breakage, not
  F2-owned; SLA minimal unblock applied with this disclosure: dropped the
  third arg at the call site — the key list was already hardcoded
  byte-identical inside the 2-arity clause, semantics unchanged).
- Run 2: 57 tests, 1 failure —
  `test/copilot/pipeline_test.exs:470` "G5 escalation: GPM-floor-class prior
  refuse also escalates": the prior returned `{:refuse, %{code: :gpm_breach,
  ...}}` but `mechanical_prior/2` re-wrapped it with `code: :mechanical_prior`,
  so `maybe_escalated/3` (classifies on top-level `:code` against
  `@gpm_floor_codes`) passed the refuse through unescalated.
- Run 3: **57 tests, 0 failures** — gate green.

## Fix (owned file lib/ash_a2a/copilot/pipeline.ex)

`mechanical_prior/2` now surfaces the prior's own classification code when
its refuse payload carries `:code`:

```elixir
{:refuse, %{code: code} = reason} -> {:refuse, %{code: code, reason: reason}}
{:refuse, reason} -> {:refuse, %{code: :mechanical_prior, reason: reason}}
```

Full reason payload preserved; atom-reason priors (e.g. the DenyingPrior
court) keep `code: :mechanical_prior` — the existing court still passes.

## Composition invariants (verified via the passing gate)

- Moduledoc stage order matches code order: Vince → Tony strain →
  attestation → authority (last gate before admit). Confirmed by the G4
  court asserting Vince consulted exactly once when the authority hop
  refuses last.
- Authority-refused leaves Vince/Tony counters untouched:
  `new_state.bridge[:coord_a].tensor.active_leases == 0`, Vince ledger `%{}`
  on the AllowAll-admit path, no mesh mutation on the refusing path
  (test/copilot/pipeline_test.exs G4 block).
- Escalated proposal carries `requires_signature: true` on every card option
  (B5 invariant, asserted on both multisig and prior-refuse escalations).
- Admit increments bridge `active_leases` (Z7 admit court).
- Full copilot court green (the 57/0 above).

## Commands / exits

- `MIX_BUILD_ROOT=_build-laneF2 mix test test/copilot/ test/attention/ test/authority/`
  → run 3 exit 0, `57 tests, 0 failures`.

## Disclosure (cross-lane edit)

- `lib/ash_a2a/ingress/channel.ex:167` — one-line SLA minimal unblock
  (3-arity call → 2-arity call, identical hardcoded key list). Disclosed
  here; the owning lane supersedes on landing.
