# ARD v26.10.2 — Documentation Drift Closure (ERRC)

**Status:** EXECUTED (2026-10-02, see ERRC_TRACKER.md cycle 1)
**Release:** v26.10.2
**Repository:** `seanchatmangpt/ash_a2a`
**Owner:** ash_a2a
**Dependencies:** v26.9.31 docs alignment (`75c386e`, `2630787`), mock-discipline gate
(`debdc1a`), existing doc courts (`docs_truth_test`, `spec_mapping_doc_test`,
`release_path_test`)
**Authority ceiling:** CONSTRUCT + verification only — docs, tests, and one
test-harness code default; no wire, authority, or dispatch-path change

## Architecture objective

Every claim in README and the connected docs is re-derived by an executable
court at test time, so documentation alignment stops being a per-release
manual pass and becomes a mechanical failure list. Hand-maintained duplicate
version sites and hand-synced catalogs are eliminated or reduced to
court-enforced surfaces; the doc quality bar (moduledocs, HexDocs coverage)
is raised to match what the module index already promises.

## Provenance

The v26.9.31 alignment pass (2026-10-02) re-aligned README + connected docs
by hand and recorded every residual gap it chose not to fix. This ARD turns
each residual gap into an ELIMINATE / REDUCE / RAISE / CREATE action. Source
evidence: `git show 2630787`, the claim-lint run over the aligned tree
(798 modules checked), and the grep-verified gap list in the PRD.

## Components

- **Version-site reduction** — exactly one restated package-version site
  outside `mix.exs` (`docs/reference/a2a-spec-version-mapping.md`, already
  drift-court-enforced); `docs/jira/*/HANDOFF.md` and `docs/how-to/release.md`
  stop restating the version; `release_path_test` shrinks accordingly.
- **Configuration truth court (generalized)** — `AshA2A.DocsTruthTest`
  extended from 3 gated keys to every documented default row in
  `docs/reference/configuration.md`, each verified by running the real
  consumer entry point (existing oracle-independence convention).
- **Telemetry catalog court** — telemetry.md event families compared against
  an emit-site registry collected from the compiled beam files
  (`AshA2A.BeamFile`-style scan), covering literal events, `:telemetry.span`
  -derived `:exception` events, and variable-built suffix families declared
  on their emitter modules.
- **Mix-task catalog court** — mix-tasks.md rows vs the real
  `Mix.Tasks.*` `@shortdoc`s: every shipped task documented, every documented
  task shipped, shortdoc text matches.
- **Module-index court** — the alignment pass's claim lint as an ExUnit
  court: every `AshA2A.*` citation in the indexed docs resolves to a real
  module; every relative docs link resolves.
- **README example court** — the README's DSL/dispatch snippets compiled and
  executed against real fixtures (the `docs_truth_test` Governed pattern).
- **Moduledoc raise** — `@moduledoc` for the 13 undocumented SPIFFE/AuthZEN
  files so the index's HexDocs links resolve to real pages.
- **ExDoc extras completeness** — README-linked docs that promise HexDocs
  presence are in `mix.exs` `docs: [extras: ...]` or explicitly marked
  repo-only in the README pointer group.
- **Machine-independent topology root** — `:chicago_topology_root` loses its
  `/Users/sac` default (typed refusal when unset outside `:dev`), code and
  doc row in one change.
- **Changelog structure guard** — exactly one `## [Unreleased]` header
  (the stray `## [Unreleased] - 2026-09-25` at line 114 is deleted).

## ERRC quadrants

| Quadrant | Items |
| --- | --- |
| **ELIMINATE** | EL1 hand-synced `Version:` sites (HANDOFF, release.md ritual — the per-release red court); EL2 stray duplicate `[Unreleased]` changelog header; EL3 manual catalog re-derivation passes (replaced by RD1–RD4 failure lists) |
| **REDUCE** | RD1 config-default drift surface (court covers every documented key, not 3); RD2 telemetry catalog drift; RD3 mix-task catalog drift; RD4 module-index/link drift; RD5 README example drift |
| **RAISE** | RA1 moduledoc coverage for indexed modules (13 SPIFFE/AuthZEN files); RA2 HexDocs extras completeness for README-linked docs; RA3 honest test-count reporting (re-measured + stamped, or ranges + reproduce command) |
| **CREATE** | CR1 red-first (anti-vacuity) requirement for every new doc court; CR2 machine-independent `:chicago_topology_root`; CR3 `docs/jira/v26.10.2/ERRC_TRACKER.md` continuing the v26.9.14 tracker lineage |

Parked (real engineering gaps, owned elsewhere — recorded, not executed here):
DurableServer cross-node rehome unexercised; framed C2 clients without TLS;
mTLS declared-but-unsupported on the auth path. Each stays a disclosed gap in
its reference doc; none is closed by a docs release.

## Invariants

1. Outside `mix.exs`, exactly one file restates the package version
   (`a2a-spec-version-mapping.md`), and the drift court enforces it. No other
   doc may carry a `Version: v<pkg>` line.
2. Every default stated in `configuration.md`'s tables is either verified by
   running the real consumer or carries no default cell; the court refuses
   unverified defaults.
3. Every telemetry event family emitted from `lib/` appears in
   `telemetry.md`, and every documented family has an emit site; Chicago
   harness families stay quarantined in their internal section.
4. Every shipped mix task has a mix-tasks.md row whose purpose text matches
   the task's `@shortdoc`.
5. Every `AshA2A.*` module citation and every relative `docs/` link in the
   indexed docs resolves in the tree.
6. Every module linked from `index.md` resolves to an ExDoc page with a
   description (`@moduledoc` or `@doc`-derived).
7. Every new doc court ships a red-first witness (a mutation the court
   detects), per the repo's anti-vacuity law.
8. Nothing in this change touches dispatch, authority, receipts, or the wire;
   the only code change is the `:chicago_topology_root` default refusal
   (test-harness scope).

## Failure/refusal boundaries

- Documented default ≠ observed default → court red, naming key, documented
  value, observed value (existing `docs_truth_test` shape).
- Emit site without catalog row, or catalog row without emit site → court red
  naming the family.
- Task without row, row without task, shortdoc mismatch → court red.
- Unresolvable module citation or broken docs link → court red.
- `:chicago_topology_root` unset outside `:dev` → `:chicago_topology_root_unset`
  typed refusal.
- Second `Version:` restatement site or second `[Unreleased]` header → court red.

## Qualification court

- `mix test test/ash_a2a/docs_truth_test.exs` (generalized) — green on the
  aligned tree; red-first witness: a deliberately wrong documented default.
- New: telemetry catalog court, mix-task catalog court, module-index court,
  README example court — each green + one red-first mutation witness each.
- `mix test test/ash_a2a/a2a_transport/spec_mapping_doc_test.exs
  test/ash_a2a/supply_chain/release_path_test.exs` — green under the reduced
  version-site set.
- `mix docs` builds with no description-less pages among index-linked modules.
- `mix test test/ash_a2a_mock_discipline_test.exs` stays green (no new code
  positions).

## Boundary law

Doc = claim; court = admission. A doc row without a court is O (candidate),
not O*. Manual alignment passes are the exception to retire, not the process
to repeat. ERRC discipline: eliminate the ritual, reduce the drift surface,
raise the floor, create only courts that can refuse.

## History

| ts | standing | action |
| --- | --- | --- |
| 2026-10-02 | DRAFT | ARD drafted from the v26.9.31 alignment-pass gap list; PRD + ERRC_TRACKER seeded alongside |
