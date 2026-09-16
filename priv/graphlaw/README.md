# Vendored GraphLaw WebAssembly Artifact

The single semantic engine artifact that every SA2A runtime executes. It is
vendored (not built here, not reimplemented here) precisely so that different
hosts can be shown to run *the same bytes*.

## The artifact

| Property | Value |
| --- | --- |
| File | `praxis_graphlaw_wasm.wasm` |
| Size | 3,249,361 bytes |
| SHA-256 | `187688d9e7e33a575713d6911d75687adb38713ed37412e211af263dfcbe0c28` |
| Engine version (self-reported) | `praxis-graphlaw v26.7.5` |
| Source | `praxis/crates/praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm` |
| Build target | `wasm-bindgen`, **bundler** target |

`praxis-graphlaw` self-describes as a law-state engine providing native N3,
Datalog, SPARQL 1.1, SHACL and ShEx, with RDFC-1.0 canonicalization via
`oxrdf`. No Elixir reimplementation of any of that exists or should exist in
this repository: the BEAM side owns the envelope, standing, refusal typing,
authority, receipts, admission orchestration, and the A2A boundary — and calls
this artifact for semantics.

## Exported functions

| Export | Arity | Returns |
| --- | --- | --- |
| `graphlaw_version` | 0 | engine version string |
| `graph_hash` | 1 (`ttl`) | hex BLAKE3 of the graph's canonical N-Quads form |
| `blake3_hex` | 1 (`data`) | hex BLAKE3 of raw UTF-8 bytes |
| `run_hooks` | 2 (`base_ttl`, `event_ttl`) | JSON `HookRunResult` |
| `validate_all` | 5 (`ttl`, `profile_ttl`, `shacl_shapes`, `shex_schema`, `shex_shape_map`) | JSON `PlaygroundResult` |

Every one of these returns a JSON object `{"error": "..."}` rather than
trapping on failure, so **callers must check for the `error` key** instead of
relying on an exception.

## Host requirements

The module is a bundler-target wasm-bindgen artifact. Two consequences for any
host:

1. It declares two host imports from the module name
   `./praxis_graphlaw_wasm_bg.js`:
   `__wbindgen_object_drop_ref` (no-op) and
   `__wbg_getRandomValues_3f44b700395062e5` (fill `(ptr, len)` in linear
   memory). A host that does not supply both cannot instantiate the module.
2. Strings cross the boundary by pointer/length using the module's own
   allocator (`__wbindgen_export2` / `__wbindgen_export4`) and a 16-byte
   shadow-stack return slot (`__wbindgen_add_to_stack_pointer`).

The bare `wasmtime` CLI therefore cannot run it — measured, not assumed:

```text
$ wasmtime run --invoke graphlaw_version praxis_graphlaw_wasm_bg.wasm
Error: failed to run main module ...
Caused by:
  0: failed to instantiate ...
  1: unknown import: `./praxis_graphlaw_wasm_bg.js::__wbindgen_object_drop_ref`
     has not been defined
```

A real host program is required. `native/graphlaw_host` is one (Wasmtime,
non-BEAM), driven from Elixir by `AshA2A.GraphLaw.RuntimeB`.

## Why the digest is load-bearing

RFC-SA2A-001's portable-semantic-execution claim is conditioned on
`WASM_A = WASM_B`. That premise is a *falsifier*, not an assumption: the native
host reports the SHA-256 of the bytes it actually compiled, and
`AshA2A.GraphLaw.RuntimeB` independently hashes the file it pointed the host at
and refuses any result whose digests disagree
(`{:error, %{code: :wasm_digest_mismatch}}`). Quote `:wasm_sha256` from a
result in a conformance receipt; do not assume it.

## The finite conformance suite

`conformance_vectors.json` records the exact inputs and the exact strings this
artifact returned for them, plus the artifact digest those expectations were
recorded against. It is the single source of truth both runtimes are driven
from, so Runtime A and Runtime B cannot drift apart by each keeping their own
typed-in copy of the expectations. Load it via
`AshA2A.GraphLaw.ConformanceVectors`.

It is a *finite* suite. Agreement across it supports the portable-semantic-
execution claim and nothing broader: not universal semantic equivalence, not
production readiness, not security completeness, and not cross-implementation
equivalence.

## See Also

- `lib/ash_a2a/graph_law/runtime_b.ex` — the BEAM-side subprocess wrapper
- `lib/ash_a2a/graph_law/conformance_vectors.ex` — the shared vector loader
- `native/graphlaw_host/src/main.rs` — the non-BEAM Wasmtime host and ABI notes
- `test/ash_a2a/graph_law/runtime_b_test.exs` — real conformance vectors
