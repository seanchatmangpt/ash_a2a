# v26.9.17 production-readiness documentation dry run (operator-ordered)

Operator order (2026-09-17): "launch 10 sub agents to do a deep dive on
this project, update README.md, docs, diataxis, etc to make sure that sa2a
is ready for production usages v26.9.17 dry run".

## Method

- 10 read-only Explore subagents fanned out in parallel (within the ≤16
  heavyweight flash ceiling; rider was operator-cut at 18:24Z the same
  day, but a separate automation loop was still landing merges on `main`
  every few minutes — hence all edits were made in the isolated worktree
  `/Users/sac/ash_a2a-wt/docs-prod-readiness` on branch
  `docs/v26.9.17-production-readiness`, base `5d07e47`).
- Every load-bearing claim in the output was re-verified first-party
  (file:line) before publication; three subagent claims were corrected by
  verification (architecture-verifier check count; `A2A.Client` return
  shapes; the Oban delivery/`ObanAuthority.reconstruct` API, which
  differs from the first draft).
- Link integrity check (all relative links in README + docs/ resolve) and
  `mix.exs` syntax check passed.

## Defects fixed (each verified against code before writing)

1. README claimed a "vendored `:a2a` SDK" linking `a2aproject/a2a` —
   false twice over: `:a2a` is a published Hex package
   (`actioncard/a2a-elixir`). Fixed.
2. README claimed CI builds both native binaries — CI builds `hddl_cli`
   only. Fixed.
3. `mix.exs` hex package omitted `docs/` while `docs()` extras required
   9+ files under `docs/` — `mix hex.publish` could not build its own
   docs. Quadrants now ship (`docs/jira`, `docs/rfc`, `litho.docs`,
   `research` deliberately excluded).
4. getting-started's `Supervisor.start_link([{A2A.AgentSupervisor, ...}])`
   snippet raised `:already_started` in any real host app (the library's
   own `AshA2A.Application` already runs that supervisor). Replaced with
   the config-booted path + direct `start_link` alternative.
5. getting-started cited a nonexistent persisted `:ash_a2a_capability_index`
   key and missed the zero-config public-action projection default.
6. getting-started never reached HTTP serving — added a full Step 4
   (`A2A.Plug` + Bandit + card curl + JSON-RPC + `A2A.Client`).
7. CHANGELOG: two `## [Unreleased]` sections; no `[26.9.17]` cut;
   stale defect wording (both v26.9.17 hardening defects were already
   fixed in `1f06cab` — `peer.ex` parse witness, `command_worker.ex`
   `verify_live!`). Restructured with closure annotations and
   `[26.9.15]`/`[26.9.16]` pointers.
8. `docs/reference/index.md`: broken anchor (version-dated heading);
   stale v26.9.14 stamps; missing module rows. Fixed + de-dated the
   target heading.
9. `docs/explanation/architecture.md`: stale intro (claimed the
   admission layer "sits beside the default path"), brittle "9/9" check
   count, missing IrAdmissionSeal/ReceiptOutbox/Reconciliation/KillSwitch
   coverage. Fixed.
10. auth how-to recommended a broker-level `revoke` and cited the private
    `Agent.resolve_skill_name/2`; no "not supported" list (mTLS,
    delegated token validation). Fixed.
11. OCEL how-to taught manual `attach!/0` (auto since v26.9.15), said
    "two handlers" (three), missed `:ocel_max_in_flight`/shed. Fixed.
12. k8s/README base-image tag drift vs `swarm/Dockerfile`;
    `swarm/config/runtime.exs` comment named a nonexistent manifest
    filename. Fixed; cookie-Secret prerequisite + probe-absence note
    added.

## New production documentation

- `SECURITY.md` (root).
- Reference: `docs/reference/dsl.md`, `configuration.md`,
  `telemetry.md`, `mix-tasks.md`, `a2a-endpoint-contract.md`.
- Explanation: `docs/explanation/message-lifecycle.md`.
- How-to: `docs/how-to/verify-authority-on-async-paths.md`,
  `docs/how-to/test-your-ash_a2a-app.md`.
- ExDoc: `groups_for_extras` Diataxis sidebar, 10 new extras,
  `source_url`/`homepage_url`.

## Disclosed open items (deliberately not done in this pass)

- B2–B10 benchmark modules still unwired into `Bench.@benchmarks`
  (code change, shared file).
- No `Spark.DocIndex` wired, so HexDocs cannot render DSL schemas
  natively (dsl.md stands in).
- CommandBus tail-latency-under-sustained-load pattern remains open
  (banner added to the stress report; it is disclosed, not hidden).
- Missing-release CHANGELOG entries for 26.9.15/.16 are pointer stubs, not
  reconstructions (would require git-history mining to write truthfully).
- Follow-up candidates: consequential-skills tutorial, HDDL planning
  tutorial, deploy-swarm how-to, `docs/index.md` landing page,
  `kill-switch` how-to.

## History

| ts (local) | standing | branch + SHA | gates + exits | remaining |
| --- | --- | --- | --- | --- |
| 2026-09-17 ~20:40 | ALIVE (research) | main @ 5d07e47 | 10/10 subagents returned; 0 tokens written to main checkout | integration |
| 2026-09-17 ~21:15 | ALIVE (integration) | docs/v26.9.17-production-readiness (pre-commit) | link check clean; `mix.exs` syntax OK; 22 files changed | commits + merge |
| 2026-09-17 (final) | PARTIAL_ALIVE | see commits below | docs verified statically; **no `mix docs`/`mix test` run in worktree (no deps)** — HexDocs render + full suite unexecuted | render check on merge; suite on next CI run |

## Receipt

- 比 (ratio): this session's deliverable is documentation on the product
  surface; all 22 files were agent-researched + operator-session-written
  (0% marketplace-manufactured — a known 産面 exposure, ledgered here;
  the reusable artifact is the dry-run method itself, a candidate for a
  docs-readiness pack).
- What the operator did NOT write: everything — all 10 research reports,
  all verification, all 22 file changes, commits, and this ticket.
- Falsifiers attempted: link-integrity sweep (0 broken), mix.exs syntax
  parse (OK), first-party re-verification of every API cited in new docs
  (3 corrections caught). Not executed: `mix docs` render and `mix test`
  (worktree has no deps; canonical tree is under an active automation
  loop) — recorded as the standing UNKNOWN for this pass.
