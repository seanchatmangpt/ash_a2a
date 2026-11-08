# Lane W3 — Z11 Actuation Residue Receipt

Standing: PASS

## Lane / files

- Lane W3, repo /Users/sac/ash_a2a (no git commands run).
- lib/ash_a2a/actuation/engine.ex — submit/3 happy path returned
  `{:ok, receipt, {:ok, ledger}}` (settle/3's raw tuple) where the @spec,
  moduledoc, and court all contract `{:ok, receipt, ledger}` with a bare-map
  ledger. Fixed by unwrapping settle's result in submit (also propagates a
  `{:refused, :already_settled}` through submit instead of embedding it).
- lib/ash_a2a/actuation/engine.ex — submit only accepted module adapters;
  two court cases pass `(ticket, ctx)` funs (spy + failing). Engine now
  accepts both (`is_function(adapter, 2)`).
- test/actuation/engine_court_test.exs — `mint/1` helper passed field
  overrides (e.g. `payload:`) as Keyword opts that `Ticket.Mint.ticket/2`
  ignores, so the "tampered/different payload" case minted an identical
  ticket (id determinism test failed on `refute changed.id == t1.id`). The
  lib digest law is correct; fixed the helper to merge field overrides.
- Residue NOT present: the reported `:adapter_nonce` failure class was
  already fixed on disk (adapter.ex:35 `Map.get(ctx, :adapter_nonce, "")`).

## Gates (commands / exits)

- `MIX_BUILD_ROOT=_build-laneW3 mix compile` → exit 0 ("Generated ash_a2a app").
- `MIX_BUILD_ROOT=_build-laneW3 mix test test/actuation/` → before: 9 tests,
  4 failures; after fixes: **9 tests, 0 failures**.
- Combined path-mode gate (see z18 receipt): 19 tests, 0 failures, 1 skipped.

## Disclosure

- The mint/1 helper fix is test-side; the two engine.ex edits are lib-side
  (behavior contract was already documented as bare ledger + module-or-fun
  adapter now stated in @doc).
