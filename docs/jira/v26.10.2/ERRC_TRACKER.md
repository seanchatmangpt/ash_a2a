# ERRC tracker — ash_a2a v26.10.2 (documentation drift closure)

Started 2026-10-02. Scope: the verified residual gaps from the v26.9.31
README/connected-docs alignment pass (`75c386e`, `2630787`), framed as
ELIMINATE / REDUCE / RAISE / CREATE actions. Spec: `ARD.md` + `PRD.md` in
this directory. Lineage: `docs/archive/jira/v26.9.14/ERRC_TRACKER.md` and the
`Cr4`/lane-P1-A2 mock-discipline item already executed in `debdc1a`.

Item ids match the ARD's ERRC quadrants and the PRD's functional
requirements (1:1). Every executed item appends its cycle entry below with:
subject SHA, commands + exits, and what the court now covers.

## Cycle 0 (2026-10-02) — categorization, nothing executed

### ELIMINATE

- [ ] **EL1** — hand-synced `Version:` sites: `docs/jira/v26.9.29/HANDOFF.md`
      and `docs/how-to/release.md` stop restating the package version;
      `release_path_test` shrinks to `mix.exs` ↔ spec-mapping and refuses any
      new restatement site. (This pass's Lane A went red→green purely on
      these two lines; the ritual is the defect.)
- [ ] **EL2** — stray duplicate `## [Unreleased] - 2026-09-25` header,
      `CHANGELOG.md:114`; plus a one-header structure guard.
- [x] **EL3** — manual catalog re-derivation passes (the 26.9.31 pass itself)
      — retired the moment RD1–RD4 land; until then any future drift fix must
      NOT be done by hand first and court second. (Execution order: courts
      first, then fix what they flag.)

### REDUCE

- [ ] **RD1** — `AshA2A.DocsTruthTest`: 3 gated keys → every default row in
      `configuration.md`, oracle = run the real consumer with app env deleted.
- [ ] **RD2** — telemetry catalog court (doc families ↔ beam-file emit-site
      registry, both directions; Chicago harness families quarantined).
- [ ] **RD3** — mix-task catalog court (rows ↔ `@shortdoc`, both directions).
- [ ] **RD4** — module-index court (claim lint as ExUnit: `AshA2A.*`
      citations, relative docs links, task names over README + reference).
- [ ] **RD5** — README example court (compile + execute the README's
      DSL/dispatch snippets on real fixtures).

### RAISE

- [ ] **RA1** — `@moduledoc` for the 13 undocumented SPIFFE/AuthZEN files
      (`grep -rln @moduledoc lib/ash_a2a/{spiffe,authzen}/` → 2 of 15 today).
- [ ] **RA2** — HexDocs extras: add `test-governed-actions.md` +
      `migrate-legacy-to-strict.md`; admit or repo-only-mark the control-plane
      pointer group; court enforces README-links ↔ extras consistency.
- [ ] **RA3** — test-taxonomy counts: re-measure with stamped commands or
      replace with reproduce-command + ranges (`test-your-ash_a2a-app.md`
      still says "as of v26.9.21").

### CREATE

- [ ] **CR1** — red-first witness for every new court (anti-vacuity law;
      `docs_truth_test`'s deliberate-mismatch test is the pattern).
- [ ] **CR2** — `:chicago_topology_root` `/Users/sac` default → typed
      `:chicago_topology_root_unset` refusal outside `:dev`
      (`sa2a_v26_9_17_topology.ex:97`) + doc row in the same change.
- [x] **CR3** — this tracker seeded (cycle 0).

### Parked (real engineering gaps — disclosed, not docs-closable)

- DurableServer cross-node rehome unexercised (disclosed in
  `reference/index.md` adapter row).
- No TLS on the framed C2 clients (disclosed in `reference/c2-wire-interop.md`).
- mTLS declared-but-unsupported (`how-to/authenticate-agent-requests.md`).
