# HILT Graph-Digest Census + Seam Decision (lane Z12, 2026-11-07)

Standing: ALIVE (standalone court 4/0; full `mix compile`/`mix test` BLOCKED by pre-existing killed-lane WIP in `lib/ash_a2a/copilot/pipeline.ex` — undefined `record/3` — and `lib/ash_a2a/authority/source/allow_all.ex`; neither file is mine, neither touched)

## Census table (claimed vs found)

| Claimed primitive | Exists? | Evidence (file:line) |
|---|---|---|
| `Hilt.WorkOrder.bind_command/2` | EXISTS | `lib/ash_a2a/hilt/work_order.ex:211-231` |
| `graph_digest` on work order | EXISTS | `lib/ash_a2a/hilt/work_order.ex:71` (field), `:140-144` (format validation), `:192` (carry-by-default from subject) |
| `checkpoint_graph_digest/2` pin-at-admit comparison | EXISTS | `lib/ash_a2a/hilt/work_order.ex:284-295` (both-present-and-disagreeing → `:stale_graph_identity`; either absent → skip) |
| Refusal `:stale_graph_identity` | EXISTS | `lib/ash_a2a/hilt/work_order.ex:32` (in `@refusal_codes`, class `:refused_identity`) and `:295` |
| `admit_command/2` wired into CommandBus | EXISTS | `lib/admission at lib/ash_a2a/command_bus.ex:1265-1281` (`hilt_work_order/2` gate before claim) |
| Chicago court + mutation + tests | EXISTS | `lib/ash_a2a/chicago/courts/hilt_work_order.ex` (CHI-HILT-001..005), `lib/ash_zero? no — lib/ash_a2a/chicago/mutation/catalog.ex:249-262` (MUT-HILT), `test/hilt_work_order_graph_digest_test.exs` |
| Digest PRODUCTION (hashing the work-order/subject graph) | EXISTS on the ash_a2a side | `AshA2A.Actuation.digest/1` canonical hash; `AshA2A.SemanticSubject` carries `graph_digest` (`lib/ash_a2a/semantic_subject.ex:15-48`); `for_command!/3` carries subject digest at `work_order.ex:188-192` |

Verdict: the operator's Article-15 claim is fully grounded — every named primitive exists, is court-covered, and is wired through the real CommandBus admission chain. The prose matches the code.

## Decision

The inline admit-time comparison exists, but nothing PERSISTS the pin across admit→actuation: nothing stops a graph digest that changed between admission and a later actuation of the same order id. So the seam is the missing half, not the comparison. Implemented `AshA2A.Authority.GraphPin`:

- `pin/3` (order_id, digest, opts) — pin at admit; re-pin is the recovery path
- `assert_fresh/3` (order_id, current_digest, opts) — `:ok` | `{:error, :stale_graph_identity` + `:unpinned` fail-closed | `:invalid_digest`
- behaviour-pluggable store (`AshA2A.Authority.GraphPin.Store` behaviour), default in-memory `Store.Memory` (Agent-backed), proof on a real second backend (ETS) in court
- never computes digests and never grants authority — stores and compares only; digest PRODUCTION lives in `SemanticSubject`/`Actuation.digest/1` where HILT graphs are built

## Court ladder (standalone, real exits)

`elixirc -o /tmp/z12_ebin lib/.../graph_pin.ex` → exit 0
`elixir /tmp/z12_court.exs` → 4 tests, 0 failures: pin→fresh :ok→mutate→`:stale_graph_identity`→re-pin recovers; fail-closed `:unpinned`; invalid-digest refuse on both ports; real ETS-backend pluggability; order-keyed isolation.

The court killed one real defect pre-landing: malformed digest `"sha256:ZZ"` at `assert_fresh` returned `:stale_graph_identity` (fixed: format check now precedes the comparison → `:invalid_digest`).

## Gates status

- `mix compile` full tree: BLOCKED, exit 1 — pre-existing `lib/ash_a2a/copilot/pipeline.ex` (`record/3` undefined, :121/:126) and `lib/ash_a2a/authority/source/allow_all.ex:8` undeclared function. NOT lane Z12's files; owner lanes must land those. Once the tree compiles, `mix test test/authority/graph_pin_test.exs` (parse-checked OK) runs the full court incl. WorkOrder-format parity case.
