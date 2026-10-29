# GraphLaw v26.10.28 Compatibility

What `ash_a2a` requires of the `graphlaw` engine after the v26.10.28
release, and where the consumer surface is pinned.

Version: v26.10.28

## Requirements

| Requirement | Detail |
|---|---|
| `ash_graphlaw` version | `~> 26.10` (`mix.exs:347`) with the v26.10.28 blake3 registry regeneration — `surface_blake3` and `receipt_surface_blake3` must be the post-v26.10.28 values (`graphlaw` `src/registry/emit_json.rs:666`, `src/registry/emit_json.rs:674`), re-pinned through the registry sync flow (`graphlaw-registry` bin), never hand-edited. |
| `hook_reactor` surface | `AshA2A.Semantic.HookReactor.Engine` (`lib/ash_a2a/semantic/hook_reactor/engine.ex`) evaluates through `AshGraphLaw.capabilities/1`, `hooks/2`, and `call/2`. `open/1` keys the runtime off the engine-reported `surface_blake3` (`engine.ex:26`); the surface digest must match what the linked engine reports or the digest is carried as `nil` rather than a stale value. |
| Retired ops | graphlaw v26.10.28 retired the legacy `validate_all` / `N3_DENIAL` op pair. `Engine.matches?/3` fails closed with the typed refusal `:hook_n3_denial_unported` (`engine.ex:100-107`) for N3-denial conditions — it never silently reports a denial verdict. Re-route: parse the condition as N3 over the projected data and derive admitted/refused through `AshGraphLaw.n3/2` (TODO, `engine.ex:95-99`). |
| Second praxis seam | The vendored `priv/graphlaw/praxis_graphlaw.wasm` law package (`mix.exs:501`) is unaffected: it consumes the wasm artifact directly and does not pass through the retired `validate_all`/`N3_DENIAL` surface. |

## See Also

- `docs/reference/a2a-spec-version-mapping.md` — version pinning conventions
- `lib/ash_a2a/semantic/hook_reactor/engine.ex` — hook evaluation surface
- graphlaw `docs/refusals.md` — typed refusal register, append-only codes
