# GraphLaw WASM Integration

v26.9.16. How `ash_a2a` obtains, verifies, and executes the GraphLaw semantic law package, and
why the Elixir side of this system deliberately owns no validation logic at all.

Audience: anyone touching `priv/graphlaw/`, `lib/ash_a2a/graphlaw/`, or the two vendor Mix tasks.
RFC sections: S21 (Root Manifest), S27 (projection, not truth), S46, S79.

## Quick Reference

| Thing | Where |
| --- | --- |
| Vendored artifact | `priv/graphlaw/praxis_graphlaw.wasm` |
| Root manifest | `priv/graphlaw/MANIFEST.json` |
| Conformance fixtures | `priv/graphlaw/fixtures/{base,reordered,mutated}.ttl` |
| JS host (raw instantiation) | `priv/graphlaw/host/graphlaw_host.mjs` |
| Rebuild + re-vendor | `mix ash_a2a.vendor_graphlaw` |
| Verify committed package | `mix ash_a2a.verify_graphlaw` |
| Elixir path helpers | `AshA2A.GraphLaw` |
| Real execution boundary | `AshA2A.GraphLaw.WasmHost` |
| Digests + canonical JSON | `AshA2A.GraphLaw.Manifest` |
| Pipeline hops | `AshA2A.GraphLaw.Vendor` |

## What GraphLaw is, and that it is reused rather than reimplemented

GraphLaw (`praxis-graphlaw`) is the user's own prior Rust work: a law-state engine with native
N3, Datalog, SPARQL 1.1, SHACL and ShEx, forked from `pbonte/roxi`. It carries real modules for
SHACL validation, closure and equivalence, ShEx and ShExC parsing, Datalog, N3 `log:` builtins,
SPARQL, OWL-RL, DRed, RSP, and the `chatman` admission/router/compensation/quarantine stack. It
depends on `oxrdf` with the `rdfc-10` feature, which is where canonical graph identity
(RDFC-1.0) actually comes from.

`ash_a2a` **calls** that engine. It does not reimplement any part of it, and it must not start
to. This repository contains no SHACL engine, no ShEx engine, no Datalog evaluator, no N3
reasoner, no SPARQL implementation, and no RDF canonicalization algorithm. The division is:

- **GraphLaw (Rust, compiled to WASM)** owns every graph-shaped judgement: canonical graph
  identity, SHACL/ShEx validation, hook evaluation, admission verdicts.
- **Elixir** owns envelope, standing, refusal typing, authority, receipts, admission
  orchestration, and the A2A boundary.

This is not only a design preference, it is also what the Elixir dependency set can actually
support. Measured on Hex: there is no `shacl`, `n3`, `rdf_canon`, or `rdf_canonicalization`
package, and `shex` 0.1.4 pins `rdf ~> 0.9`, which cannot resolve against the `rdf ~> 3.0` this
project's graph stack already uses. Writing that machinery by hand in Elixir would mean
reimplementing, in a second language, an engine the user already wrote and already tests.

## Why raw instantiation instead of wasm-pack's JS glue

`wasm-pack` emits a `.wasm` plus JS glue tailored to one JS host. None of those shapes is usable
from the BEAM, and the glue is not needed: the module imports only two host functions, both
trivial.

```text
./praxis_graphlaw_wasm_bg.js::__wbindgen_object_drop_ref        -> no-op
./praxis_graphlaw_wasm_bg.js::__wbg_getRandomValues_3f44b700395062e5
                                                                -> fill (ptr,len) with random bytes
```

`priv/graphlaw/host/graphlaw_host.mjs` therefore instantiates the raw module directly and
supplies those two imports itself. It discovers the import *module name* from the module's own
import list rather than hardcoding it, so it keeps working if the build target changes.

### The wasm-bindgen string ABI

This is the hard-won part. A `String`-returning function taking N `&str` parameters is not
callable directly; it uses an indirect return area and caller-managed linear memory.

```text
__wbindgen_export2(len, align)                  -> ptr     (malloc)
__wbindgen_export3(ptr, old_len, new_len, align)-> ptr     (realloc)
__wbindgen_export4(ptr, len, align)             -> ()      (free)
__wbindgen_add_to_stack_pointer(-16)            -> retptr  (+16 afterwards to restore)
```

The call sequence:

1. `retptr = __wbindgen_add_to_stack_pointer(-16)`.
2. For each string argument: UTF-8 encode it, `ptr = __wbindgen_export2(len, 1)`, copy the bytes
   into linear memory at `ptr`. Ownership transfers to the callee; do not free these.
3. Call `fn(retptr, ptr0, len0, ptr1, len1, ...)`.
4. Read two little-endian `i32` at `retptr + 0` and `retptr + 4`; these are `(resultPtr,
   resultLen)`.
5. UTF-8 decode `resultLen` bytes at `resultPtr`.
6. `__wbindgen_add_to_stack_pointer(16)` to restore, then `__wbindgen_export4(resultPtr,
   resultLen, 1)` to free the result.

Every export re-reads `memory.buffer` before use, because allocation can grow the memory and
invalidate a previously captured `ArrayBuffer`.

### Exports actually present

```text
memory              blake3_hex          graph_hash          graphlaw_version
init_panic_hook     run_hooks           validate_all        __abort_handler
__instance_terminated                   __wbindgen_start
__wbindgen_export   __wbindgen_export2  __wbindgen_export3  __wbindgen_export4
__wbindgen_add_to_stack_pointer
```

Signatures used by this repository:

```text
graphlaw_version()                                                     -> String
graph_hash(ttl)                                                        -> hex String
blake3_hex(text)                                                       -> hex String
run_hooks(base_ttl, event_ttl)                                         -> JSON String
validate_all(ttl, profile_ttl, shacl_shapes, shex_schema, shex_map)    -> JSON String
```

All of them signal failure **in band**, by returning `{"error": "..."}` as JSON, rather than by
trapping. Every caller must check for the `"error"` key.
`AshA2A.GraphLaw.WasmHost.call_json/3` does this and maps it to a typed
`{:error, %{code: :graphlaw_error}}`.

## The vendor pipeline

```text
locate praxis  ->  wasm-pack build --release  ->  EXECUTE the result  ->  install + manifest
(flag/env/~)       (real toolchain)               (acceptance gate)        (real digests)
```

Step 3 is the load-bearing one. An artifact that has not been run is never vendored. Acceptance
is not "it loaded"; it is three real semantic properties measured over the committed fixtures:

- `base.ttl` and `reordered.ttl` describe the same graph with a **different prefix label** and a
  **different triple order**. Their `graph_hash` must be **identical** (RFC S12 canonical graph
  identity). If this only tested a single file, it would prove nothing about canonicalization.
- `mutated.ttl` changes one triple. Its `graph_hash` must **differ**.
- `blake3_hex("abc")` must equal the published BLAKE3 test vector, which pins the artifact's own
  hash primitive to a value derived entirely outside this repository.

If any of these fails, the task writes nothing and reports `:artifact_rejected`.

### Running it

```bash
mix ash_a2a.vendor_graphlaw                                      # ~/praxis, bundler target
mix ash_a2a.vendor_graphlaw --praxis /path/to/praxis --target web
mix ash_a2a.vendor_graphlaw --target-dir /tmp/wasmtarget --dry-run
mix ash_a2a.verify_graphlaw                                      # CI: no praxis, no Rust, no net
```

The praxis location is resolved as `--praxis`, then `$PRAXIS_ROOT`, then `~/praxis`. No absolute
path is hardcoded as the only option; a consumer of this library will not have a praxis checkout
at all, and that is a supported state, not an error condition of the library.

### Absent praxis is a first-class state

`mix ash_a2a.vendor_graphlaw` needs praxis and a Rust toolchain. `mix ash_a2a.verify_graphlaw`,
`AshA2A.GraphLaw.WasmHost`, and everything downstream need **neither**. The typed error, measured
by actually running the task against a nonexistent directory:

```text
** (Mix) [praxis_not_found] no praxis checkout at /nonexistent/praxis
(expected /nonexistent/praxis/crates/praxis-graphlaw-wasm/Cargo.toml).
Pass --praxis <dir> or set PRAXIS_ROOT. This is not fatal for consumers: the
committed priv/graphlaw artifact and manifest remain usable without a praxis checkout.
```

## The root manifest (S21), which is a projection and not truth (S27)

`MANIFEST.json` binds a content address to a provenance record and to a real executed
verification: artifact name, byte length, SHA-256, BLAKE3; the praxis git SHA, both crate
versions, the wasm-pack target and version, the rustc version, and the build timestamp; the
observed host imports/exports and the string ABI; and the actual values the acceptance probe
returned.

`AshA2A.GraphLaw.Manifest.canonical_json/1` emits recursively key-sorted JSON so that
`content_digest` (SHA-256 over that canonical form, excluding the `content_digest` key itself) is
stable regardless of map iteration order. `mix ash_a2a.verify_graphlaw` recomputes it, so editing
the manifest body without re-stamping is caught.

None of this grants anything. A matching digest is evidence of byte identity; a passing probe is
evidence the module still runs. Neither is authority. Every real consequence still has to pass
`AshA2A.CommandBus`.

BLAKE3 is computed by the real `b3sum` executable. There is no BLAKE3 implementation in this
dependency set, and this repository will not hand-roll one, so when `b3sum` is absent the value
is reported as a named `SKIP` rather than silently passing. SHA-256 comes from `:crypto` and is
never skipped.

## Real measurements taken while building this pipeline

All of the following were produced by actually running the commands, on macOS 25.2.0 with
`rustc 1.97.0 (2d8144b78 2026-07-07)`, `wasm-pack 0.13.1`, `wasm-bindgen 0.2.126`, Node v26.8.1.

### The wasm-pack target does not affect the module at all

Building the same source at praxis `bf96ea5` for three different targets:

```text
target     bytes     sha256
bundler    3248401   0582d595cd0d474fad90d67f1918509281067e6b8dc315df6048d8967edbec1a
web        3248401   0582d595cd0d474fad90d67f1918509281067e6b8dc315df6048d8967edbec1a
nodejs     3248401   0582d595cd0d474fad90d67f1918509281067e6b8dc315df6048d8967edbec1a
```

Byte-identical across all three. Only the JS glue differs, and this repository does not use the
glue. All three declare the same import module name (`./praxis_graphlaw_wasm_bg.js`) and the same
two import functions. The answer to "which target is more host-portable" is therefore: none of
them, and it does not matter. Portability comes from instantiating the module directly, which is
what `graphlaw_host.mjs` does. `bundler` is kept as the default only because it is what the
existing artifact was built with.

### Is wasm-pack output byte-reproducible?

**Within one toolchain, yes. Across toolchains, no.**

Two separate `mix ash_a2a.vendor_graphlaw` runs over the same source on the same machine both
produced `0582d595cd0d474fad90d67f1918509281067e6b8dc315df6048d8967edbec1a`.

Against the committed artifact, which was built from the same source SHA on 2026-07-08 with an
older toolchain:

```text
committed (2026-07-08)  3249361 bytes
  sha256 187688d9e7e33a575713d6911d75687adb38713ed37412e211af263dfcbe0c28
rebuilt   (2026-09-16)  3248401 bytes
  sha256 0582d595cd0d474fad90d67f1918509281067e6b8dc315df6048d8967edbec1a
```

Different size, different digest, same source. So the content address pins *an artifact*, not
*a source revision*; a consumer cannot re-derive the committed bytes from the praxis SHA alone
without also pinning the exact rustc and wasm-bindgen versions, which the original build did not
record.

What **is** reproducible is the semantics. The committed artifact and all three rebuilt targets
return identical `graphlaw_version()` and identical `graph_hash` over all three fixtures:

```text
graphlaw_version()          praxis-graphlaw v26.7.5
graph_hash(base.ttl)        9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d
graph_hash(reordered.ttl)   9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d
graph_hash(mutated.ttl)     610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66
```

This is a narrow, useful result and should not be overstated: it is semantic agreement on a
three-fixture suite between two builds of the *same* source by *different* toolchains. It is not
a claim about arbitrary inputs, and it is not cross-implementation equivalence.

### BLOCKED: praxis HEAD does not compile for wasm32

At praxis HEAD (`31f149dd8a6d6b4ff25f27ba24b53759c20954c9`), `wasm-pack build --target
wasm32-unknown-unknown` fails:

```text
error[E0599]: no associated function or constant named `open` found for struct `Store`
   --> crates/praxis-graphlaw/src/chatman/engine.rs:597:28
597 |         let store = Store::open(path).map_err(|e| {
    |                            ^^^^ associated function not found in `Store`
note: if you're trying to build a new `Store`, consider using `Store::new`
   --> oxigraph-0.5.9/src/store.rs:169:5
```

`oxigraph`'s on-disk `Store::open` is RocksDB-backed and does not exist in a wasm build; only
`Store::new` (in-memory) does. The host-target `cargo build --release -p praxis-graphlaw` exits 0,
so this is specific to `wasm32-unknown-unknown`. Fixing it belongs in praxis (a
`#[cfg(not(target_family = "wasm"))]` guard around the persistent-store path), not here.

The consequence for this repository: `mix ash_a2a.vendor_graphlaw` against praxis HEAD currently
fails with `:wasm_pack_failed` and the real compiler output attached. That is the pipeline
working as designed. The committed artifact remains the v26.7.5 build, and everything downstream
of it keeps working. Rebuilds were verified against praxis `bf96ea5`, which does compile.

### Two environment defects found and repaired along the way

- `wasm-pack`'s tool cache at
  `~/Library/Caches/.wasm-pack/wasm-bindgen-cargo-install-0.2.126/` had its `wasm-bindgen` and
  `wasm-bindgen-test-runner` binaries written mode `600`, so every build failed with
  `... /wasm-bindgen is not executable` *after* a successful compile. Repaired with `chmod +x`.
- Elixir's `System.cmd/3` has no `:input` option (it raises `invalid option :input`), so
  `AshA2A.GraphLaw.WasmHost` passes its request through a real temp file whose path is `argv[2]`
  of the host script. The host still accepts stdin when no path is given, so it stays usable by
  hand.

## Testing discipline

`test/ash_a2a/graphlaw_vendor_test.exs` is Chicago-school throughout: it instantiates and
executes the real committed `.wasm`, writes real files to real temp directories, computes real
digests over real bytes, and probes the real `wasm-pack` / `b3sum` / `node` executables on the
real `PATH`. There are no mocks, no stubs, and no interaction assertions; every assertion is on
returned state, file contents, or a digest. Where Node is genuinely unavailable, execution tests
emit a named, visible skip rather than substituting a fabricated result.

## See Also

- `docs/explanation/architecture.md` — where the semantic boundary sits in the wider system
- `docs/how-to/enable-semantic-requests.md` — the consumer-facing semantic request path
- `lib/ash_a2a/planning/hddl_solver.ex` — the native-subprocess pattern `WasmHost` follows
- `lib/ash_a2a/command_bus.ex` — the consequence boundary nothing in this document bypasses
- `lib/ash_a2a/semantic/ontology.ex` — the sort-then-hash `fingerprint/1` that `graph_hash`
  is intended to replace for RFC S12 purposes
