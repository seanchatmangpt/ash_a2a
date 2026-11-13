# Lane a-authority Receipt

Standing: PARTIAL_ALIVE

## Subject / files

- lib/ash_a2a/dispatcher.ex: reads `AshA2A.Info.authority_gate/1` (`:disabled` refuses anchored
  skills, stage `:authority_gate`) and `AshA2A.Info.hooks/1` (pre fails closed, stage
  `:pre_dispatch_hook`; post logged). Hook ids resolve via `config :ash_a2a, :dispatch_hooks`
  `%{id => {Mod, :fun}}`; unresolved id refuses.
- lib/ash_a2a/verify.ex: removed hooks and `:disabled` inert warnings (now enforced); `:open` and
  lease_duration_ms warnings retained.
- test/dsl_mapping_card_test.exs: hooks warning assertion flipped to refute.
- test/ash_a2a/authority/dispatch_hooks_test.exs (new): gate + pre/post hooks fire; deny; unresolved.

## Commands + exits

`MIX_ENV=test MIX_BUILD_ROOT=_build-w2-a-authority mix test test/ash_a2a/authority
test/dsl_mapping_card_test.exs test/ash_a2a_dispatcher_skill_name_shape_test.exs`: 48 tests, 0 failures
(exit code not captured through pipe; failure count read from output).

## Disclosures

- protocol/agent.ex untouched. dispatcher.ex has pre-existing uncommitted edits by others; mine are additive.
- AllowAll: already refuses `:prod` via compile-time env; NO_CHANGE_NEEDED for the guard that exists.

## Not done

- AllowAll true runtime (release) guard, `:unpinned` switches: not examined.
- `:open` gate and lease_duration_ms remain unenforced (warned).
- Gate refusal for `:disabled` on an anchored skill not exercised by a test.
