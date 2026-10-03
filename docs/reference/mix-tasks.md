# Mix Tasks Reference

All tasks live in `lib/mix/tasks/`. Run `mix help <task>` for full flags.

## Installer

| Task | Purpose |
| --- | --- |
| `mix ash_a2a.install` | Igniter task wiring the `AshA2A` extension into a project (merges into an existing `extensions:` list). Also available as `mix igniter.install ash_a2a`. |

## CI gates

These are the repo's own regression gates (run by or alongside
`.github/workflows/ci.yml` via `mix test`):

| Task | Shortdoc |
| --- | --- |
| `mix ash_a2a.verify_architecture` | Runs real, executable architecture-invariant checks (CI gate) — capability-index derivability, unknown-consequence refusal, change-requires-authority, fingerprint invariants, sole-DO fence, semantic gates. |
| `mix ash_a2a.verify_adapters` | Runs the cross-adapter 'no ambient DO' regression guard (CI gate). |
| `mix ash_a2a.verify_conformance` | Runs the real RFC-SA2A-001 conformance profile checks (CI gate). |
| `mix ash_a2a.verify_graphlaw` | Verifies the committed GraphLaw wasm law package against its manifest (CI-suitable). |

## Conformance & courts

| Task | Shortdoc |
| --- | --- |
| `mix ash_a2a.sa2a_conformance` | Runs the SA2A portable semantic execution conformance court (dual real runtimes over `priv/sa2a_conformance/`). |
| `mix ash_a2a.chicago` | Runs the RFC-SA2A-002 Chicago conformance court. |
| `mix ash_a2a.chicago.bench` | Runs the RFC-SA2A-002 benchmarks (all 10 categories, B1-B10) in one invocation (`--only B1,B9`-style selection, iterations/warmup/out flags; results are content-addressed). Since 2026-09-18 the seven newer benchmark modules (B2, B3, B4, B6, B7, B8, B10) are wired into the run-all dispatch, no longer standalone. |
| `mix ash_a2a.chicago.mutate` | Runs the RFC-SA2A-002 §22/§97 anti-vacuity mutation catalog. |
| `mix ash_a2a.chicago.pin_court_manifest` | Rebuilds `priv/sa2a/chicago_court_manifest.json` from the compiled courts. |
| `mix ash_a2a.sa2a.pin_root_manifest` | Rebuilds `priv/sa2a/root_manifest.json` from the real conformance corpus. |
| `mix ash_a2a.c2.court` | Runs the RFC-SA2A-006 s26 C2 compromise court against the real `authority_service` and `actuator` OS processes — plays an attacker controlling the control-plane node and judges every attack from the actuator's hash-chained effect ledger. `--n` repetitions, `--only` attack selection, `--no-mutation` skips the mutation court; tagged `:c2_court` (`:serial`, `:serial_solo`). See [C2 compromise court](c2-compromise-court.md). |

## Tooling

| Task | Shortdoc |
| --- | --- |
| `mix ash_a2a.vendor_graphlaw` | Rebuilds, executes, and vendors the GraphLaw wasm law package into `priv/graphlaw` (needs the praxis checkout and `wasm-pack`; dev tooling only). |
| `mix ash_a2a.standing_ref` | Prints the newest SHA with a durable court receipt at a given standing (`--court sa2a --standing CONFORMANT`), so consumers pin that exact SHA as a git `ref:` instead of a version number. See `AshA2A.StandingRef`. |
| `mix eds.ledger` | Print the real ERC ledger for this repo — the ERC (Executable Research Claim) receipts written from this project's own test-run evidence. |

## Benchmarks (non-task)

`bench/ash_a2a_bench.exs` is a standalone script (not a mix task):

```sh
mix run bench/ash_a2a_bench.exs
```

It measures dispatch/compile/command-bus paths (p50/p95/p99, 100 timed
iterations) with inline fixtures. The RFC-SA2A-002 suite proper is
`mix ash_a2a.chicago.bench` above.
