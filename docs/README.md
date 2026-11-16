# ash_a2a Documentation — Diátaxis Index

This directory is the canonical navigation surface for current ash_a2a documentation,
organized by Diátaxis quadrants. Current behavior is defined by executable code and
tests; prose records only what those surfaces support.

## Tutorials

Learning-oriented, end-to-end paths:

- [`tutorials/getting-started.md`](tutorials/getting-started.md) — install the package,
  wire the `a2a` DSL into an Ash domain, and run a first dispatch end to end.

## How-to guides

Goal-oriented procedures:

- [`how-to/approver-apps.md`](how-to/approver-apps.md) — build apps whose primary
  purpose is approving governed agent actions.
- [`how-to/authenticate-agent-requests.md`](how-to/authenticate-agent-requests.md) —
  authenticate inbound A2A requests and thread identity into your Ash actions.
- [`how-to/enable-semantic-requests.md`](how-to/enable-semantic-requests.md) — enable
  the semantic-compilation A2A surface in an existing app.
- [`how-to/v1-1-live-and-generations.md`](how-to/v1-1-live-and-generations.md) — use live
  messaging, generations, timeline and resubscribe at A2A v1.1
- [`how-to/migrate-from-a2a-hex.md`](how-to/migrate-from-a2a-hex.md) — drop
  `{:a2a, "~> 0.2"}` and move to `AshA2A.Protocol.*`.
- [`how-to/migrate-legacy-to-strict.md`](how-to/migrate-legacy-to-strict.md) — move
  from legacy permissive behavior to the strict conformance profile.
- [`how-to/observe-dispatch-with-ocel.md`](how-to/observe-dispatch-with-ocel.md) — get
  OCEL v2 process-mining evidence for every A2A dispatch.
- [`how-to/mount-email-gateway.md`](how-to/mount-email-gateway.md) — authenticate email
  provider webhooks and send briefs through a spool or SMTP sender.
- [`how-to/operate-by-email.md`](how-to/operate-by-email.md) — operate governed actions
  by email brief and reply.
- [`how-to/release.md`](how-to/release.md) — cut an ash_a2a release.
- [`how-to/run-conference-sim.md`](how-to/run-conference-sim.md) — run the
  conference-sim court suite end to end.
- [`how-to/run-the-simulation-server.md`](how-to/run-the-simulation-server.md) — boot
  every transport over one agent with real Ash mutations and prove each served
  method, route and RPC over the wire (`mix ash_a2a.sim --prove`).
- [`how-to/check-a2a-v1-1-parity.md`](how-to/check-a2a-v1-1-parity.md) — compare every
  response of the simulation server with a reference encoder built from the upstream
  v1.1 proto (`mix ash_a2a.sim --parity`).
- [`how-to/control-the-sim-over-mcp.md`](how-to/control-the-sim-over-mcp.md) — drive
  every A2A operation of the simulation server from an MCP client
  (`mix ash_a2a.sim.mcp`, `bin/a2a-sim-mcp`, `scripts/mcp_drive.py`).
- [`how-to/run-mutation-testing.md`](how-to/run-mutation-testing.md) — run mutation
  testing over the security surface.
- [`how-to/run-pplan-courts.md`](how-to/run-pplan-courts.md) — run the ash_pplan parity
  courts (`mix ash_a2a.pplan_courts`).
- [`how-to/copilot-demo.md`](how-to/copilot-demo.md) — run the end-to-end copilot demo.
- [`how-to/run-the-copilot-pipeline.md`](how-to/run-the-copilot-pipeline.md) — drive
  `Copilot.Pipeline` with its options.
- [`how-to/secure-an-a2a-deployment.md`](how-to/secure-an-a2a-deployment.md) — the
  deployed security surface: auth plug, owner scoping, credential hygiene,
  wire-input hardening, card signatures, admission limits.
- [`how-to/test-governed-actions.md`](how-to/test-governed-actions.md) — test governed
  actions without mocks (Chicago style).
- [`how-to/test-your-ash_a2a-app.md`](how-to/test-your-ash_a2a-app.md) — test your own
  ash_a2a app and run this repo's own suite.
- [`how-to/use-role-based-llm-resolution.md`](how-to/use-role-based-llm-resolution.md) —
  add an LLM-backed action without hardcoding a provider.
- [`how-to/verify-authority-on-async-paths.md`](how-to/verify-authority-on-async-paths.md) —
  verify authority on async (Oban) delivery paths.
- [`how-to/approve-over-the-wire.md`](how-to/approve-over-the-wire.md) — submit signed
  human approvals to the authority service's `"approve"` op (the Swift approver side is
  not run here).
- [`how-to/optional-dependencies.md`](how-to/optional-dependencies.md) — which
  dependencies are optional and what each guarded module does when one is absent
  (the compile-matrix script passes locally; its CI workflow has not run).
- [`how-to/run-doctor.md`](how-to/run-doctor.md) — diagnose an app's A2A wiring with
  `mix ash_a2a.doctor`.
- [`how-to/sign-agent-cards.md`](how-to/sign-agent-cards.md) — sign and verify agent
  cards with detached JWS (`AshA2A.Protocol.AgentCardSignature`).
- [`how-to/verify-receipts.md`](how-to/verify-receipts.md) — check Markdown receipts
  against the files they cite with `mix ash_a2a.receipts.verify`.

## Reference

Exact factual contracts:

- [`reference/index.md`](reference/index.md) — module reference index: the
  ALIVE / ALIVE (opt-in trigger) / REAL_INTEGRATED / PARTIAL standing legend and the
  full reference page catalog.
- [`reference/a2a-error-mapping-decisions.md`](reference/a2a-error-mapping-decisions.md) — HTTP,
  gRPC and JSON-RPC error mapping decisions against the pinned TCK
- [`reference/dsl.md`](reference/dsl.md) — the `a2a` section, `skill`,
  `hddl_operator`, `semantic_requests`, and compile-time verification.
- [`reference/configuration.md`](reference/configuration.md) — every application config
  key and environment variable the library reads.
- [`reference/telemetry.md`](reference/telemetry.md) — the production event catalog
  with payloads.
- [`reference/mix-tasks.md`](reference/mix-tasks.md) — the shipped Mix tasks.
- [`reference/performance.md`](reference/performance.md) — the measured v1.0 wire-path
  baseline (SA2A-B5/B9 bench run with its environment-identity receipt).
- [`reference/a2a-endpoint-contract.md`](reference/a2a-endpoint-contract.md) — the
  served HTTP wire surface: card, JSON-RPC, errors, streaming, auth.
- [`reference/a2a-spec-version-mapping.md`](reference/a2a-spec-version-mapping.md) —
  A2A spec-version mapping.
- [`reference/graphlaw-v26.10.28-compat.md`](reference/graphlaw-v26.10.28-compat.md) —
  the graphlaw v26.10.28 (blake3-era) consumer compatibility note: retired ops,
  blake3 keys, wasm vendoring.
- [`reference/a2a-v1-conformance.md`](reference/a2a-v1-conformance.md) — per-spec
  CONFORMANT/PARTIAL/GAP claims, each citing the executed v1 conformance court.
- [`reference/a2a-v1-1-conformance.md`](reference/a2a-v1-1-conformance.md) — per-spec
  v1.1 conformance claims.
- [`reference/v1-1-known-divergences.md`](reference/v1-1-known-divergences.md) — KD register
  for the v1.1 target: rc-proto snapshot, no v1.1 TCK, untriaged and env-gated courts.
- [`reference/tck-suite.md`](reference/tck-suite.md) — running the in-repo v1
  conformance report (`mix ash_a2a.v1_conformance_report`) and the official
  `a2aproject/a2a-tck` suite: court inventory, witnessed verdicts, and what
  MUST-class failures convert to.
- [`reference/a2a-v1_1-readiness.md`](reference/a2a-v1_1-readiness.md) — the a2a
  roadmap triaged against the code on disk, with the TCK cross-reference.
- [`reference/c2-certificate.md`](reference/c2-certificate.md) — the canonical
  `AshA2A.C2.Certificate` wire form and its verifier input.
- [`reference/c2-compromise-court.md`](reference/c2-compromise-court.md) — the
  executable RFC-SA2A-006 s26 court over the actuator's hash-chained effect ledger.
- [`reference/c2-wire-interop.md`](reference/c2-wire-interop.md) — C2 wire interop.
- [`reference/conference-sim-model.md`](reference/conference-sim-model.md) —
  conference-sim model.
- [`reference/conformance-claim.md`](reference/conformance-claim.md) — conformance
  claim.
- [`reference/conformance-profiles.md`](reference/conformance-profiles.md) —
  conformance profiles and the strict C1 run.
- [`reference/enterprise.md`](reference/enterprise.md) — enterprise reference.
- [`reference/security-advisories.md`](reference/security-advisories.md) — security
  advisories disposition.
- [`reference/ingress-attestation.md`](reference/ingress-attestation.md) — attestation
  `Key`/`Gate`/`GateGrantAllowlist` and `Ingress.Channel`.
- [`reference/module-coverage.md`](reference/module-coverage.md) — public module families
  with no dedicated doc (standing `undocumented`).
- [`reference/qme-1.md`](reference/qme-1.md) — QME-1 ecosystem reference: this
  repository's role (PreparedEffect, receipt and replay consequence protocol) and its
  binding to the canonical chatman-ecosystem specification.
- [`reference/a2a-v1-1-parity-findings.md`](reference/a2a-v1-1-parity-findings.md) —
  open and fixed findings of the v1.1 parity check, including the version-gating cases.
- [`reference/agent-card-honesty.md`](reference/agent-card-honesty.md) —
  `AgentCard.audit/2`: discrepancy codes between a card's claims and the mounted
  surface.
- [`reference/event-journal.md`](reference/event-journal.md) — the
  `AshA2A.Protocol.EventJournal` callback contract for per-task event replay.
- [`reference/fuzz-findings-v26.11.15.md`](reference/fuzz-findings-v26.11.15.md) — wire
  decoder fuzz findings for v26.11.15.
- [`reference/release-readiness-v26.11.15.md`](reference/release-readiness-v26.11.15.md) —
  remaining release blockers for v26.11.15; a checklist, not a release claim.
- [`reference/security-review-v26.11.15.md`](reference/security-review-v26.11.15.md) —
  by-eye adversarial security review of unrun v26.11.15 code.
- [`reference/generated/`](reference/generated/README.md) — GENERATED doc-hdit
  reference skeletons: a rigid, machine-rendered table of every module and public
  item on the extracted code surface (regen command in its README; never
  hand-edited).

## Explanation

Conceptual architecture and rationale:

- [`explanation/architecture.md`](explanation/architecture.md) — the layered
  architecture: capability projection, admission/receipts, and the ecosystem adapters
  as real integrations.
- [`explanation/canonical-graph-identity.md`](explanation/canonical-graph-identity.md) —
  canonical graph identity (RFC S12).
- [`explanation/chicago-conformance-court.md`](explanation/chicago-conformance-court.md) —
  the Chicago conformance court.
- [`explanation/closure-implementations.md`](explanation/closure-implementations.md) —
  closure implementations: one owner per law.
- [`explanation/copilot-membrane.md`](explanation/copilot-membrane.md) — the copilot
  membrane: pipeline stages, attestation refusal classes, authority hop.
- [`explanation/ggen-marketplace-integration.md`](explanation/ggen-marketplace-integration.md) —
  semantic A2A generation and domain extension via ggen-marketplace.
- [`explanation/graphlaw-wasm-integration.md`](explanation/graphlaw-wasm-integration.md) —
  GraphLaw WASM integration.
- [`explanation/message-lifecycle.md`](explanation/message-lifecycle.md) — message
  lifecycle.
- [`explanation/pplan-seams.md`](explanation/pplan-seams.md) — the two independent
  ash_pplan seams and why they do not delegate to each other.
- [`explanation/v26.9.29-fibo-high-value-chicago.md`](explanation/v26.9.29-fibo-high-value-chicago.md) —
  v26.9.29 Chicago court over the FIBO high-value finance corpus.

## Archive

`archive/` holds historical RFCs, reports, receipts, tickets and session history.
It is evidence of past states, not current behavior; current claims live in the
quadrants above. `sjira/` holds ticket-ontology data (`.ttl`), not prose docs.

## Capability standing rules

- **ALIVE** requires observed execution against the exact admitted subject.
- Source inspection, workflow presence, test names, and documentation are not
  execution proof.
- When local execution is unavailable, exact-head GitHub CI may qualify the changed
  subject, but only successful runs on the exact head are admitted.
- Semantic projections and generated/read models have no ambient execution authority.
