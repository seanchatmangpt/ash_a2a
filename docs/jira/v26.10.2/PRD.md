# PRD v26.10.2 — Documentation Drift Closure (ERRC)

**Status:** DRAFT IMPLEMENTATION SPEC
**Release:** v26.10.2
**Repository:** `seanchatmangpt/ash_a2a`
**Owner:** ash_a2a
**Dependencies:** v26.9.31 docs alignment (`75c386e`, `2630787`), mock-discipline gate
(`debdc1a`), existing doc courts (`docs_truth_test`, `spec_mapping_doc_test`,
`release_path_test`)
**Authority ceiling:** CONSTRUCT + verification only — docs, tests, and one
test-harness code default; no wire, authority, or dispatch-path change

## Product outcome

Documentation alignment is mechanical: `mix test` fails with a named,
actionable diff whenever README or a connected doc drifts from the
implementation, and no human re-derivation pass is required at the next
release.

## Problem

The v26.9.31 alignment pass fixed ~40 drifted claims by hand and left a
verified gap list. Root cause is structural: the repo's doc courts gate only
3 config keys, 1 method matrix, and 3 version sites, while the docs restate
~60 config keys, ~13 telemetry families, 15 mix tasks, ~95 module rows, and
2 hand-synced version sites. Anything restated without a court drifts again
on the next feature wave. Additionally, 13 of 15 SPIFFE/AuthZEN modules have
no `@moduledoc`, so `index.md` links point at description-less HexDocs
pages, and two README-linked how-tos are absent from the HexDocs extras.

## Verified gap list (evidence per item)

| Gap | Evidence |
| --- | --- |
| Hand-synced `Version:` in `HANDOFF.md` + `release.md` break `release_path_test` on every bump | this session's Lane A red-before-fix |
| Stray duplicate `## [Unreleased] - 2026-09-25` header | `CHANGELOG.md:114` |
| `docs_truth_test` gates 3 of ~60 documented keys | `test/ash_a2a/docs_truth_test.exs:19` |
| Telemetry catalog was ~13 families behind lib emit sites | `grep telemetry.execute lib/` vs `docs/reference/telemetry.md` (pre-`2630787`) |
| 2 of 15 mix tasks undocumented | `lib/mix/tasks/*.ex` vs `docs/reference/mix-tasks.md` (pre-`2630787`) |
| 13/15 SPIFFE/AuthZEN files without `@moduledoc` | `grep -rln @moduledoc lib/ash_a2a/{spiffe,authzen}/` |
| `test-governed-actions.md`, `migrate-legacy-to-strict.md` README-linked but not in `mix.exs` docs extras | `grep mix.exs` |
| `:chicago_topology_root` defaults to `/Users/sac` | `lib/ash_a2a/chicago/courts/sa2a_v26_9_17_topology.ex:97` |
| Test-count claims stamped "as of v26.9.21" | `docs/how-to/test-your-ash_a2a-app.md` |

## Functional requirements

1. **(EL1)** `HANDOFF.md` and `how-to/release.md` stop restating the package
   version; `release_path_test` checks `mix.exs` ↔ spec-mapping only, and
   gains a refusal on any new `Version: v\d+\.\d+\.\d+` restatement outside
   the one admitted site.
2. **(EL2)** Delete the stray `## [Unreleased] - 2026-09-25` header; court
   asserts exactly one `## [Unreleased]` header in `CHANGELOG.md`.
3. **(RD1)** Generalize `AshA2A.DocsTruthTest`: every `| \`key\` |` row with a
   default cell in `configuration.md` is verified against the real consumer
   (run the entry point with app env deleted, oracle-independence rule).
   Rows whose default is genuinely env-dependent keep the `—` cell and are
   exempt by explicit allowlist.
4. **(RD2)** Add the telemetry catalog court: parse `telemetry.md` families;
   collect emit sites from compiled beam files (literal + `:span`-derived +
   declared suffix families); refuse both directions of drift. Chicago
   harness families remain allowed only inside the internal section.
5. **(RD3)** Add the mix-task catalog court: rows vs `@shortdoc`s, both
   directions, text compared.
6. **(RD4)** Add the module-index court: the claim lint (module citations,
   relative links, task names) as an ExUnit test over README + reference
   docs.
7. **(RD5)** Add the README example court: compile and execute the README's
   DSL/dispatch snippets against real fixtures (Governed pattern from
   `docs_truth_test`).
8. **(RA1)** Write real `@moduledoc`s for the 13 undocumented SPIFFE/AuthZEN
   files (content grounded in each module's public functions; no restating
   of the index rows).
9. **(RA2)** Add `test-governed-actions.md` and `migrate-legacy-to-strict.md`
   to `mix.exs` docs extras; add the HexDocs-bound subset of the README
   control-plane group (at minimum `c2-certificate.md`, `c2-wire-interop.md`,
   `conformance-claim.md`, `conformance-profiles.md`) or mark the rest
   repo-only in the README pointer group; court: every README-linked doc is
   in extras or explicitly marked repo-only.
10. **(RA3)** Re-measure the test-taxonomy numbers with the exact stamped
    commands, or replace exact counts with the reproduce commands plus
    ranges; the doc states which.
11. **(CR1)** Every new court ships a red-first witness test (mutate the
    doc/registry, assert detection), per the `docs_truth_test` anti-vacuity
    pattern.
12. **(CR2)** Replace the `:chicago_topology_root` `/Users/sac` default with
    a typed `:chicago_topology_root_unset` refusal outside `:dev`; update the
    configuration.md row in the same change.
13. **(CR3)** Seed `docs/jira/v26.10.2/ERRC_TRACKER.md` with cycle 0 (this
    categorization) and append one cycle per execution batch.

Parked (explicitly out of scope, stay disclosed in their reference docs):
DurableServer cross-node rehome; TLS on the framed C2 clients; mTLS support.

## Acceptance criteria

1. `mix test test/ash_a2a/docs_truth_test.exs` — green, and its count of
   gated default rows equals the count of default cells in
   `configuration.md` (asserted by the court itself, not by hand).
2. Each new court (telemetry, mix-task, module-index, README-example) is
   green, and each has one witnessed red-first mutation.
3. `mix test test/ash_a2a/supply_chain/release_path_test.exs
   test/ash_a2a/a2a_transport/spec_mapping_doc_test.exs` — green with HANDOFF/
   release.md no longer carrying version lines; a planted second
   `Version: v` restatement is refused.
4. `grep -c '^## \[Unreleased\]' CHANGELOG.md` == 1 (and the court enforces
   it).
5. `mix docs` succeeds; every module linked from `index.md` renders with a
   description; spot-check: `AshA2A.SPIFFE.Identity`,
   `AshA2A.AuthZEN.DecisionGate` pages non-empty.
6. `:chicago_topology_root` unset in a `:test`-like non-dev env refuses
   `:chicago_topology_root_unset`; `configuration.md` row states the refusal.
7. Full ladder stays green: `mix test` (fast lane) plus the four existing
   doc courts; `mix ash_a2a.verify_architecture` unchanged (9/9-class pass;
   no architecture check added or removed).
8. The CHANGELOG `[26.10.2]` entry lists what changed and the courts added.

## Evidence product

One receipt per execution batch: exact subject SHA, commands + exits
(courts, `mix docs`, red-first witnesses), files touched, and the
court-covered claim count before → after (3 → N config keys; 0 → 4 new
courts). The tracker (`ERRC_TRACKER.md`) logs each cycle per the v26.9.14
lineage format.

## Definition of done

`mix test` on a clean checkout fails whenever README or a connected doc
drifts from the implementation — with a named diff — and passes on the
aligned tree, with no documentation claim outside a court's reach except the
explicitly parked and repo-only-marked sets.

## History

| ts | standing | action |
| --- | --- | --- |
| 2026-10-02 | DRAFT | PRD drafted; gap list carried verbatim from the v26.9.31 alignment pass with evidence paths |
