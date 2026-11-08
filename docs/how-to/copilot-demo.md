# How to run the copilot pipeline demo

Standing: PASS (MIX_BUILD_ROOT=_build-laneZ19 mix run examples/copilot_demo.exs -> exit 0, all 6 stages 2026-11-07)

One script, five stages, the whole session's copilot stack: Vince
(adversarial intent evaluation) -> Tony (coordinator strain gate) ->
Attestation.Gate (Article-10 on-site attestation). Real modules only — no
mocks, no service dependencies.

## Prerequisites

- Elixir/Erlang toolchain; repo deps fetched (`mix deps.get`).
- Path-mode checkout of `ash_a2a` (no env config required; the demo does
  not set `:ash_a2a, :copilot_mechanical_prior`, and the auto-detect step
  finds no `TradeReticle.Plumbing`, so the mechanical-prior stage is
  skipped — the transcript notes nothing, the stage simply does not fire).

## Command

```sh
MIX_BUILD_ROOT=_build-demo mix run examples/copilot_demo.exs
```

Expected exit: 0. The script prints a per-stage transcript and halts.

## Stages and what each proves

| # | Stage | Proves |
|---|---|---|
| 0 | Mint ECDSA P-256 keypair (`Attestation.Key`) + sign/verify roundtrip | crypto substrate works on the Erlang stdlib alone (no JOSE dep) |
| 1 | `nte=1000, offer=500` | Vince fires the exact-half monkey-math detector: `{:challenge, %{code: :monkey_math, ...}}`, challenge ledger records the trade |
| 2 | `plumbing.drain.r2, offer=700` (GPM 0.30) + fresh signed token | repaired intent ADMITS through Tony's strain gate and the attestation gate; verified nonce/issued_at surface in the ticket claims |
| 3 | resubmit the ORIGINAL trade `plumbing.drain` | challenge-as-state: repeat challenge on the same trade escalates to `{:refuse, :escalate_multisig}` — the retry must be a new dispute file, not a resubmission |
| 4 | good intent + spoofed attestation (`is_virtual: true`) | attestation gate refuses `{:refuse, %{code: :attestation, reason: {:refused, :emulator_detected}}}` — crypto passes, claims consistency fails |
| 5 | saturated coordinator tensor | Tony sheds `{:shed, {:senior_queue, :tony_relief}}` before Vince's interrogation burns — strain-first ordering |

## Honest scope

The attestation gate verifies signature, freshness, and claim
consistency — it does not perform true hardware-enclave attestation (see
`AshA2A.Attestation.Gate` moduledoc). Stage 4's spoof is detected because
the emulator declares itself honestly via claims, which is exactly the
threat the gate covers.
