# ERRC tracker — ash_a2a v26.10.2 (documentation drift closure)

Started 2026-10-02. Scope: the verified residual gaps from the v26.9.31
README/connected-docs alignment pass (`75c386e`, `2630787`), framed as
ELIMINATE / REDUCE / RAISE / CREATE actions. Spec: `ARD.md` + `PRD.md` in
this directory. Lineage: `docs/archive/jira/v26.9.14/ERRC_TRACKER.md` and the
`Cr4`/lane-P1-A2 mock-discipline item already executed in `debdc1a`.

Item ids match the ARD's ERRC quadrants and the PRD's functional
requirements (1:1). Every executed item appends its cycle entry below with:
subject SHA, commands + exits, and what the court now covers.

## Cycle 1 (2026-10-02) — full execution of EL1/EL2/RD1–RD5/RA1–RA3/CR1–CR2

Executed in one integrated batch on `main` (concurrent-writer lanes active in
the same checkout; only this milestone's paths staged). Standing after the
verification ladder: see the cycle's receipt in the release commit.

- [x] **EL1** — `Version:` lines removed from `how-to/release.md`,
      `v26.9.29/HANDOFF.md`, `v26.9.29/README.md`, `v26.9.28-kernel/HANDOFF.md`;
      `release_path_test` shrunk to `mix.exs` ↔ spec-mapping and now REFUSES any
      second `Version: v\d+` restatement across README/CHANGELOG/reference/
      how-to/tutorials/explanation/jira. Red-first witness: the pre-existing
      mismatched-pair test plus the new refusal message naming the admitted site.
- [x] **EL2** — stray `## [Unreleased] - 2026-09-25` header deleted;
      `unreleased_header_count/1 == 1` court + witness.
- [x] **EL3** — retired by construction: RD1–RD4 courts now flag drift; the
      hand-alignment pass class is no longer the process.
- [x] **RD1** — `AshA2A.DocsTruthTest` generalized: 22 execution oracles (up
      from 3), each running the real consumer with app env deleted; positional
      parsing of multi-key rows; every documented literal default must be
      oracle-verified or allowlisted with a reason (`@documented_not_executable`
      = the shrink-never-grow map); row-scan vacuity floor (>30 gated keys).
      New public readers added to give single-site oracles (see CHANGELOG).
- [x] **RD2** — telemetry catalog court: every literal `[:ash_a2a, ...]` emit
      site in lib (non-Chicago) must be documented; 10 variable-built families
      declared per emitter file with documented prefixes; `[:a2a, ...]` span
      namespace quarantined with a doc note. telemetry.md gained ~35 previously
      undocumented families (inventory-derived).
- [x] **RD3** — mix-task catalog court: shipped tasks ↔ mix-tasks.md rows, both
      directions; every row must embed the task's exact `@shortdoc`
      (backtick/whitespace normalized). Doc rows normalized (chicago.bench,
      eds.ledger, verify_adapters).
- [x] **RD4** — module-citation court: `AshA2A.*` citations across README +
      indexed docs resolve against lib defmodules (+ registered-name
      allowlist); relative `docs/` links resolve.
- [x] **RD5** — README usage-example court: the DSL block compiles under a
      unique namespace and `AshA2A.Dispatcher.dispatch(:echo, ...)` returns the
      documented `{:reply, [%A2A.Part.Data{data: %{results: []}}]}`.
- [x] **RA1** — `@moduledoc` written for all 13 SPIFFE/AuthZEN files
      (evidence-only law stated per module); ExDoc pages non-empty.
- [x] **RA2** — extras: `test-governed-actions.md`, `migrate-legacy-to-strict.md`,
      `c2-certificate.md`, `c2-wire-interop.md`, `conformance-claim.md`,
      `conformance-profiles.md` added to `mix.exs` docs(); README control-plane
      entries not in extras marked `repo-only`; court enforces README-links ⊆
      extras ∪ repo-only.
- [x] **RA3** — test-your-ash_a2a-app.md counts restated with the reproduce
      commands; stale "as of v26.9.21" figures replaced (see the doc).
- [x] **CR1** — every new court carries a red-first witness (planted event,
      dropped task row + mutated shortdoc, ghost module/link, second
      Unreleased header).
- [x] **CR2** — `:chicago_topology_root` unset refuses
      `:chicago_topology_root_unset` (no more `/Users/sac` default);
      `config/test.exs` pins the checkout; configuration.md row updated.
      Deviation from the PRD's "outside :dev" carve-out: refusal is total
      when unset (simpler, fail-closed; dev users configure it explicitly).
- [x] **CR3** — this tracker.

Deferred (recorded, not done): RD1 allowlist shrinkage (add readers for
`:receipt_commit_retry_delays_ms`, `:claim_lease_ms`, `:receipt_store`);
pre-existing `lib/ash_a2a/consequence_kernel/call_graph_court.ex:20` and
`receipt/r_projection.ex:177` compile warnings (other lanes' files).

## Cycle 0 (2026-10-02) — categorization (every item executed in cycle 1)

### ELIMINATE

- [x] **EL1** — hand-synced `Version:` sites: `docs/jira/v26.9.29/HANDOFF.md`
      and `docs/how-to/release.md` stop restating the package version;
      `release_path_test` shrinks to `mix.exs` ↔ spec-mapping and refuses any
      new restatement site. (This pass's Lane A went red→green purely on
      these two lines; the ritual is the defect.)
- [x] **EL2** — stray duplicate `## [Unreleased] - 2026-09-25` header,
      `CHANGELOG.md:114`; plus a one-header structure guard.
- [x] **EL3** — manual catalog re-derivation passes (the 26.9.31 pass itself)
      — retired the moment RD1–RD4 land; until then any future drift fix must
      NOT be done by hand first and court second. (Execution order: courts
      first, then fix what they flag.)

### REDUCE

- [x] **RD1** — `AshA2A.DocsTruthTest`: 3 gated keys → every default row in
      `configuration.md`, oracle = run the real consumer with app env deleted.
- [x] **RD2** — telemetry catalog court (doc families ↔ beam-file emit-site
      registry, both directions; Chicago harness families quarantined).
- [x] **RD3** — mix-task catalog court (rows ↔ `@shortdoc`, both directions).
- [x] **RD4** — module-index court (claim lint as ExUnit: `AshA2A.*`
      citations, relative docs links, task names over README + reference).
- [x] **RD5** — README example court (compile + execute the README's
      DSL/dispatch snippets on real fixtures).

### RAISE

- [x] **RA1** — `@moduledoc` for the 13 undocumented SPIFFE/AuthZEN files
      (`grep -rln @moduledoc lib/ash_a2a/{spiffe,authzen}/` → 2 of 15 today).
- [x] **RA2** — HexDocs extras: add `test-governed-actions.md` +
      `migrate-legacy-to-strict.md`; admit or repo-only-mark the control-plane
      pointer group; court enforces README-links ↔ extras consistency.
- [x] **RA3** — test-taxonomy counts: re-measure with stamped commands or
      replace with reproduce-command + ranges (`test-your-ash_a2a-app.md`
      still says "as of v26.9.21").

### CREATE

- [x] **CR1** — red-first witness for every new court (anti-vacuity law;
      `docs_truth_test`'s deliberate-mismatch test is the pattern).
- [x] **CR2** — `:chicago_topology_root` `/Users/sac` default → typed
      `:chicago_topology_root_unset` refusal outside `:dev`
      (`sa2a_v26_9_17_topology.ex:97`) + doc row in the same change.
- [x] **CR3** — this tracker seeded (cycle 0).

### Parked (real engineering gaps — disclosed, not docs-closable)

- DurableServer cross-node rehome unexercised (disclosed in
  `reference/index.md` adapter row).
- No TLS on the framed C2 clients (disclosed in `reference/c2-wire-interop.md`).
- mTLS declared-but-unsupported (`how-to/authenticate-agent-requests.md`).
## Cycle 2 (2026-10-02) — RD1 allowlist shrink (5-lane fan-out) + deferred-list closure

Five coordinator-dispatched lanes over disjoint files (contract: single-site
readers, no git, no shared-file edits, syntax-proofs without _build writes;
integration of the shared docs-truth court serialized to the coordinator):

- [x] **RD1 shrink** — 36 execution oracles (up from 22): CommandBus
      `receipt_commit_retry_delays_ms/0` (7 sites unified) + `kill_switch_class/0`;
      Application `receipt_store/0`, `receipt_store_ekv_opts/0`,
      `outbox_reconciler?/0`; ClaimLease `lease_ms/0`; Semantic.Conformance
      `planning_bounds/0`/`semantic_engine/0`/`admitted_vocabulary/0`/
      `root_manifest/0`; Semantic.Compiler `max_batch/1`; Telemetry.Redact
      `raw_errors?/0`; OcelForwarder `ingest_url/0`; `:evidence_class` verified
      via the existing `Evidence.Class.default/0`. Allowlist: 54 → 19
      reason-carrying entries. configuration.md now states the semantic trio's
      real `nil` defaults and the `100` max_batch bound.
- [x] **Deferred warnings** — already eliminated at current head by the
      concurrent fleet-R lane (`1d7dc2e`); WRN lane proved it by reproducing
      both historical clause shapes and recompiling clean. `mix compile` now
      emits ZERO warnings (one lane-introduced @doc stacking in redact.ex
      caught by the forced-recompile check and fixed at integration).

Receipt: `7c13f1e` on `main` (stacked on the concurrent lane's `619bbb3`/
`1d7dc2e`). Ladder 67 passed; `mix hex.build` clean at 26.10.2
(checksum 4c8f9742…). Deferred remainder: the 19 allowlist entries (each
carries its reason; further shrinkage needs readers on per-call-override
keys or is blocked by computed/conditional defaults by design).
