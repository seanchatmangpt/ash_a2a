# Changelog

All notable changes to `ash_a2a` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

Statuses of v1.1 items below are stated conservatively: unless a test run is cited, they
are unverified. See `docs/reference/a2a-v1-1-conformance.md` for row-level status.

## [Unreleased]

### Added

- Email gateway: `AshA2A.Email.{Inbound,Brief,ReplyIntent,Plug,KernelEntry}` and
  `POST /v1/email:ingest`, turning an approver's reply to a mailed brief into governed
  dispatches. Guide: `docs/how-to/operate-by-email.md`. Unverified.
- A2A v1.1 support (target: upstream tag `v1.1.0-rc`, status PARTIAL; no v1.1 TCK verdict
  exists). Cards advertise `protocolVersion` 1.1 and `A2A-Version` accepts 0.3, 1.0 and 1.1.
  Task `generation`/`timeline`, `ifGenerationMatch` (`-32010`, HTTP 409 `ABORTED`),
  `POST /message:live`, `currentGeneration` long poll, `lastSeenGeneration` resume, and
  `userArtifacts`/`artifactUpdates`. Guide: `docs/how-to/v1-1-live-and-generations.md`.
- User-artifact support is served on the agent card (`user_artifacts`).
- Documented configuration: `:long_poll_timeout_ms`, `:events_transport`, `user_artifacts`,
  `cancel_in_flight`, `validate_input_modes`, and the mount `tenant` option
  (`docs/reference/configuration.md`).
- `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`.

### Changed

- `Message.extensions` is now a list of extension URIs (`[String.t()] | map()`, default `[]`).
- The v1.1 card decoder closes `protocolBinding` to `JSONRPC | GRPC | HTTP+JSON`.
- Tenant-aware ownership: `tenant` is read on `AshA2A.Protocol.Plug`.
- The server accepts `A2A-Version` 0.3, 1.0 and 1.1; the client-header default stays 1.0.
- README reorganized: install and quickstart first, conformance and status material last.

## [26.11.15] - 2026-11-13

### Changed

- `oban`, `ash_oban`, `ash_state_machine`, `postgrex`, `flame`, `durable_server`
  and `req_llm` are optional dependencies; a consumer compiles `ash_a2a` without
  them (verified against a path-dependent consumer project).
- The root supervisor is `:rest_for_one` (stores first) with a wider restart budget.
- ExDoc: module groups, `source_ref`, DSL reference grouped under Reference.

### Fixed

- A checkpoint the store silently dropped is no longer reported as landed
  (`Checkpoint.land/4` reads back and raises).
- Handover completion and claim release carry the claim token: a runner whose
  claim was taken over gets `:claim_lost` and cannot overwrite the peer.

## [26.11.14] - 2026-11-13

### Security

- Legacy push-notification sender resolves and refuses non-public addresses and
  never follows redirects (SSRF).
- gRPC ignores the forwarded-certificate header unless
  `trust_forwarded_cert: true`.
- `A2A-Version` echoed in a response header is limited to a short printable token.
- HTTP request bodies are depth-capped (`AshA2A.Protocol.JSONGuard`).
- Ash calls pass `authorize?: true` explicitly; `forbidden` replies and
  extended-card provider failures no longer carry internal detail.

### Fixed

- A failing checkpoint no longer aborts a node drain; a worker is evicted only
  when its frame landed.
- A failed task-event journal write is logged instead of crashing the events server.
- `KillSwitch.trip/3` waits up to 30 s so a slow disk cannot fail the halt.
- The transport worker is killed when its agent dies.
- `mix ash_a2a.gen.skill` appends into the `a2a` block and no longer defaults
  `consequence` to `observe`.
- `ash_ai` is a test-only dependency.

## [26.11.13] - 2026-11-13

### Changed

- `AshA2A.Twin.CEO` / `AshA2A.Twin.COO` replace the previous person-named twins.
- `ConsequenceKernel` wave-ID modules (W4/W4B/W4C/W5) now live under
  `Claims`, `Closure`, `Dispatch`, `Effects` and `Guards`.
- Push-notification delivery runs under `AshA2A.Protocol.PushTaskSupervisor`.
- Sibling path deps (`ash_graphlaw`, `ash_pplan`) are selected with
  `ASH_A2A_LOCAL_DEPS=1`; Hex pins are the default.
- Historical docs moved to `docs/archive`; lane-prefixed test files renamed to
  behaviour names.
- Hex package ships `priv/dfcm` and the native crate sources.

### Added

- A2A v1.1 capabilities (unverified; no test run is cited here): `message/live`,
  `StreamRequest` and `StreamError` frames, task `generation` and `timeline`,
  `TaskMessageUpdateEvent`, `timelineLength`, `ifGenerationMatch` (`-32010`),
  `currentGeneration` long poll, `userArtifacts`/`artifactUpdates`, and
  `TaskPushNotificationConfig.protocolVersion`. Vendored upstream proto at
  `priv/a2a_v1_1_spec_corpus/a2a.proto`; v1.0.1 remains supported and v0.3 is decode-only.
- `config :ash_a2a, :long_poll_timeout_ms` and the `user_artifacts` agent-card capability.
- `docs/reference/a2a-v1-1-conformance.md` and a corpus test that fails loudly on pending
  items.
- `Attestation.Gate.verify_gps_trajectory/2` and `AshA2A.Attestation.GateGrantAllowlist`:
  an approved, unexpired, in-area grant overrides a `:gps_impossible_jump` refusal; with no
  grants, behavior is identical to `/1`.
- `AshA2A.Transport.WireCompat`: conversion between the wire (`A2A.*`) and protocol
  (`AshA2A.Protocol.*`) structs at the agent boundary.
- Nonce-replay defense in `Ingress.Channel`, `AshA2A.TelemetryBridge.PplanHazard`, and
  real-supervisor durability continuity tests.
- `mix ash_a2a.pplan_courts` parity runner (`docs/how-to/run-pplan-courts.md`) and the
  `ASH_PPLAN_PATH` toggle.
- `mix ash_a2a.v1_conformance_report` derives its test list from a glob of
  `test/ash_a2a_v1_*_test.exs` and accepts `--tck-report PATH`.

### Changed

- `tasks/resubscribe` with `lastSeenGeneration` now works on both HTTP plugs; on
  `AshA2A.Transport.Plug` owned tasks attach to the live stream (previously answered
  `-32004`), with no snapshot when the client is current.
- Conformance docs now state A2A v1.0.1 (wire-compatible with v1.0.0) and record TCK
  results as `{pass, fail, not_tested, skipped, manual}` bound to a pin SHA and date.
- The CI `tck` job reads `reports/compatibility.json` and adds the gRPC transport.
- Dependency updates: `ash_pplan` 26.11.10, `ash` 3.37.4, `bandit` 1.14.1, `grpc` 1.0.6,
  `req_llm` 1.30.0.
- Verifier warning text now reflects the dispatcher's `authority gate :disabled` and
  `hooks` behavior.

### Fixed

- Wire-shaped `a2a.auth` identity maps (string keys after a JSON-RPC round trip) now
  resolve as the same identity as the in-process atom-key shape, with no widening of
  access.

## [26.10.9] - 2026-11-07

### Added

- `AshA2A.Twin` digital-twin family (`Asset`, `Partner`, `Operator`) with hazard statistics
  in `AshA2A.Twin.Hazard` and the `Twin.CEO` interrogator built on `MechanicalPrior`.
- `AshA2A.Strain.Tensor` and `AshA2A.Strain.Bridge`.
- Attestation `Key`/`Gate` and `Ingress.Channel`.
- `Copilot.Pipeline` dispatch pre-check chain, including an `:authority_source` option that
  enforces a standing check as the last gate before admit (refusal surfaces as
  `{:refuse, %{code: :authority}}`), and strain-first routing through `Strain.Bridge`.
- `AshA2A.Negotiation` (`Engine`, `Strategy`, `DefaultStrategy`), `AshA2A.Attention.Broker`
  and `AshA2A.Actuation` (`Engine`, `Adapter`, `Ticket`).
- Replanning port surface and the `ASH_PPLAN_PATH` toggle for source-local `ash_pplan`.

### Changed

- graphlaw v26.10.28 compatibility: the hook runtime keys off the engine-reported surface
  digest, and N3-denial conditions are re-derived through `AshGraphLaw.n3/2`
  (see `docs/reference/graphlaw-v26.10.28-compat.md`).
- Refusal mapping and receipt tooling updated for the new registry values.
- Dependency lock updates (`ash` 3.35.0 and others).

### Fixed

- `AshA2A.Replan.Port` no longer raises; failures return typed `{:error, _}` values.
- Hazard-bridge `Process.info` defects, twin hazard typespecs, and a `Twin.COO` guard.
- Attestation hardening: canonical low-s ECDSA signatures are enforced (malleated twins are
  refused with `:non_canonical_signature`), freshness checks bound future skew, GPS
  trajectories are validated (`:gps_impossible_jump` above 500 km in 60 s), and
  `Ingress.Channel` refuses replayed nonces.
- Terminal runs in the durable engine refuse further signals with
  `{:error, {:run_terminal, status}}` (fixed upstream in `ash_pplan`).

### Removed

- `AshA2A.SagaControl` (unused).

## [26.10.5] - 2026-10-05

### Added

- Official TCK run across all three bindings (jsonrpc, http_json, grpc) against an in-repo
  server harness: 92 pass, 7 fail, 4 skipped, 26 not tested. Details:
  `docs/reference/a2a-v1-conformance.md`. CI gained a `tck` job.
- Streaming for `message/stream` and `tasks/resubscribe` replays from the recorded task
  event log over SSE, on all three bindings.
- Agent cards carry JWS `signatures` on the wire; `AshA2A.Protocol.CardSigning` supports
  HS256, RS256 and ES256 with `kid` in the protected header.

### Changed

- Authority and envelope tests no longer hand-mint authority; they run through the real
  grant and command-bus path, and new tests pin subject/capability binding and expiry.
- In-repo census of the legacy in-memory receipt store; the `:legacy_compat` mode is
  deprecable (no in-repo consumer boots under it).

### Security

- Auth-scheme hardening: reserved-key metadata is stripped, internal error payloads are
  reference-only, push senders gate URL scheme and CRLF and default to SSRF-safe behavior,
  and the extended-card cache is private.
- `ash` 3.34.0 to 3.34.4, closing CVE-2026-94201 (high). Two cowlib advisories were
  assessed as not exposed.

## [26.10.4] - 2026-10-05

### Added

- Enterprise surface (all config-gated, default off): `AshA2A.Enterprise.Supervisor` and
  `AshA2A.Enterprise.Pipeline` (reference: `docs/reference/enterprise.md`).
- Zero-trust identity and policy: SPIFFE workload identity (`AshA2A.SPIFFE.*`), OpenID
  AuthZEN evaluation (`AshA2A.AuthZEN.*`, fail-closed `:pdp_unreachable`), and monotonic
  delegation narrowing (`:refused_non_monotonic_grant`).
- Inline DLP (`AshA2A.Security.DLPFilter`) and data residency
  (`AshA2A.Security.DataResidency`).
- CMEK envelope encryption (`AshA2A.Security.KeyManager`, AES-256-GCM, rotation without
  payload rewrite).
- Two-phase drain (`AshA2A.Cluster.DrainManager`) with cordon, tracked-task drain,
  checkpoint and handover.
- FinOps hard budget ceilings (`AshA2A.FinOps.BudgetEnforcer`).
- Affidavit and OCEL v2 evidence (`AshA2A.Evidence.Affidavit`, `AshA2A.Evidence.Ocel2`)
  and SIEM egress to Splunk HEC, Google Chronicle and Datadog Logs
  (`AshA2A.Telemetry.SIEM`).
- `AshA2A.Passport` (signed portable agent identity), `AshA2A.Trace` (OTLP/JSON task
  traces), `AshA2A.Bidi` (bidirectional streaming over SSE), and `AshA2A.Elicitation`
  (typed `INPUT_REQUIRED` contract).

## [26.10.3] - 2026-10-04

### Changed

- **Breaking:** the `:a2a` hex dependency was removed and the wire protocol retargeted to
  A2A v1.0.0. The codec is hosted in-repo as `AshA2A.Protocol.*` (ported from a2a-elixir
  0.3.0, Apache-2.0; attribution in `lib/ash_a2a/protocol/NOTICE`). The default
  `protocolVersion` is `"1.0"`, carried per entry in the card's `supportedInterfaces`
  (`"0.3"` stays listed for negotiation).
- **Breaking:** v1.0 wire shapes. Parts and stream frames carry no `kind` discriminator on
  emission (the decoder still accepts it); stream events carry no `final` boolean
  (finality is a terminal state); artifact streaming uses `append`/`lastChunk` chunking.
- **Breaking:** v1.0 error registry. `AshA2A.ToA2AError` is the single failure normalizer;
  unknown tasks map to `-32001` and A2A-range errors carry a `google.rpc.ErrorInfo` object.
- `TASK_STATE_INPUT_REQUIRED` and `TASK_STATE_AUTH_REQUIRED` are resumable non-terminal
  states; `TASK_STATE_REJECTED` is emitted for admission refusals (never `failed`).
- `mix ash_a2a.install` no longer adds `:a2a` to `mix.exs`.
- A continuation with a mismatched `contextId` is refused as not found, and new tasks get
  server-minted random context ids.

### Added

- gRPC binding (`AshA2A.Transport.GRPC.Server`): the canonical `lf.a2a.v1.A2AService` with
  9 unary and 2 server-streaming RPCs, generated from the vendored `priv/proto/a2a.proto`.
- HTTP+JSON binding (`AshA2A.Transport.HTTPJSON`): message send, task get/list/cancel,
  push-notification config CRUD, extended card, and the well-known agent card.
- `AshA2A.Executor`, `AshA2A.Domain` DSL, `AshA2A.Verifiers.VerifySkills`,
  `AshA2A.Schema` (per-skill JSON Schema), `AshA2A.Protocol.CardSigning`,
  `AshA2A.Protocol.CardCache`, extension negotiation, and the schema-advertisement card
  extension (`urn:sa2a:extension:schema:v1`).
- Durability through `ash_pplan`: `AshA2A.Providers.PPlan`, `AshA2A.Execution.PPlan` (the
  run id is the A2A task id), push-notification bridge `AshA2A.Providers.PPlanNotify`, and
  restart-proven durability. Install with `mix ash_a2a.install --with-pplan`.
- TCK run over the JSON-RPC binding: 69.2% overall compatibility (68 pass, 5 fail,
  15 skipped of 88); the remaining failures are pinned as the test server's behavior, not
  spec violations. Details: `docs/reference/a2a-v1-conformance.md`.
- Documentation: conformance statement, security guide
  (`docs/how-to/secure-an-a2a-deployment.md`), migration guide
  (`docs/how-to/migrate-from-a2a-hex.md`), performance baseline, and DSL reference.

### Fixed

- `Transport.Plug`: unsupported `A2A-Version` is refused `-32009`; `tasks/resubscribe` on an
  unknown or foreign task answers `-32001`; the agent card serves `Cache-Control`, `ETag`
  and `Last-Modified` headers.
- Streaming artifact ids are minted once per stream so chunks reassemble under one id.

### Security

- `tasks/list` is owner-scoped: it answers from the verified principal, closing anonymous
  and cross-principal task enumeration.
- `message/stream` error replies send a typed error class only, redacting task structs and
  any credential they carried.
- Auth plug: case-insensitive scheme comparison, multi-challenge 401s, and fail-closed
  verification (a raising verifier yields a generic 401).
- The extended agent card strips internal keys (`a2a.auth`, `ash_a2a.owner`, `:stream`)
  from every nested map.

## [26.10.2] - 2026-10-02

Documentation accuracy release. No wire, authority, or dispatch-path change.

### Changed

- `:chicago_topology_root` no longer defaults to a machine path; when unset it refuses with
  `:chicago_topology_root_unset`.
- Package version is restated in one documentation site only; the release-path test refuses
  any second restatement.

### Added

- Tests that verify documented configuration defaults by running the real reader, that
  every emitted telemetry event and mix task is documented, and that README examples
  compile and run.
- `@moduledoc` for all SPIFFE and AuthZEN modules; more HexDocs extras.
- Public default readers for several configuration values (for example
  `Application.agents/0`, `Health.outbox_ready_max/0`, `Planning.HddlSolver.timeout_ms/0`).

### Fixed

- Removed a duplicate `Unreleased` header; a test now enforces a single header.

## [26.9.31] - 2026-10-02

Release preparation and documentation alignment; no tag, no publish.

### Added

- `AshA2A.C2.PolicyEvidence` (AuthZEN PDP adapter) and its Req-based PDP client;
  `AuthorityService.authorize/3` gained an opt-in policy-evidence precondition
  (an allow is evidence, never a substitute for admission).
- `AshA2A.C2.PolicyEvidence.McpProjection` projects an MCP `tools/call` into a powerless
  prepared effect.
- `AshA2A.Semantic.InterchangeContract`, `AshA2A.DfCM.FleetIntake` and `AshA2A.DfCM.Court`.
- HILT graph-digest integrity: `AshA2A.Hilt.WorkOrder` can carry a `graph_digest` that is
  pinned against the executing command's semantic subject; drift refuses
  `:stale_graph_identity`.
- `AshA2A.Receipt.RProjection`, projecting command receipts onto a fleet receipt schema
  (evidence-only, deterministic).
- 33 refusal classifications for SPIFFE, semantic-interchange and standing-receipt codes.

### Changed

- The AuthZEN request `action` uses the canonical `{"name": ..., "properties": ...}` shape.
- `CapabilityRelease.freeze/2` re-admits each member's durable standing evidence and refuses
  `:standing_release_digest_mismatch` on a digest difference.
- Documentation (README, `mix-tasks.md`, `configuration.md`, `telemetry.md`, module index)
  brought in line with the implementation.

## [26.9.30] - 2026-09-30

Release preparation only: version bump; no tag, no publish.

## [26.9.29] - 2026-09-29

Release preparation only; no tag, no publish. No conformance profile is claimed:
`mix ash_a2a.verify_conformance --profile c0..c3` reported not conformant in the
development build at this release.

### Added

- Consequence kernel: runtime hardening (prepare, claim, crash-window, outcome stages,
  authenticated prepared-effect store), dispatch inversion so `CommandBus` routes through
  the kernel, and authenticated effect claims and recovery.
- C2/C3 authority: portable RFC 8785 (JCS) SHA-256 prepared-effect identity, certificate
  signing and verification, and external `authority_service/`, `actuator/` and
  `sa2a_crypto/` mix projects.
- `AshA2A.SecurityProfile` (`:strict` default, `:legacy_compat`, `:dev_bypass` compiled out
  of prod), enforced at application start.
- `mix ash_a2a.verify_conformance --profile c0..c3`, which computes a claim from executed
  probes and refuses on a dirty tree or failing probe.
- Replanning (recovery core, provider ports, bounded failover), bounded-intervention
  closure with receipt and replay paths, and semantic-work identity and replay boundaries.
- `AshA2A.SpgIdentity`, `AshA2A.ExecutionSnapshot`, `AshA2A.CapabilityRelease` (frozen
  capability lifecycle, guarding the card and the dispatcher),
  `AshA2A.ConditionalCommitment`, `AshA2A.Semantic.PolicyPhenotype`,
  `AshA2A.Hilt.WorkOrder` and `AshA2A.ExecutionIdentity`.
- Production Kubernetes/swarm manifests and the Diataxis documentation set.

### Changed

- Toolchain moved to Elixir 1.20.4 / OTP 29.1.1.
- CI uses a single release path with a non-publishing attested dry run, Dependabot and
  Scorecard.
- Closure layer deduplicated onto `Gall.Closure.*`; redundant modules removed
  (see `docs/explanation/closure-implementations.md`).
- Refusal classification extended so classification stays total for all new codes.
- `AshA2A.Command` carries an optional `:spg_identity` that joins the fingerprint.
- `AshA2A.Planning.BoundedPlan` gains `:work_order_digest`; a step claiming a different
  work-order identity is refused `:preflight_work_order_mismatch`.
- Closure identity gains a cross-runtime `portable_digest`.

### Fixed

- Raw `System.cmd` and `apply/3` sites replaced by an allowlisted executor and callback
  registry; SSRF admission for the OCEL forwarder; HDDL subprocess timeout; path
  sanitization.
- A GraphLaw subprocess release race, plus several test timing and port-allocation flakes.

### Known issues

- No C1/C2/C3 claim: several C1 probes failed in the development build.
- Supply-chain facts and built-release distribution checks were not run.

## [26.9.22] - 2026-09-23

### Added

- Scheduled conformance workflow uploading receipts for each push to main plus a daily run.
  Hosted runs report the true result (the topology tests need local sibling checkouts).
- `mix ash_a2a.install --skill name:action[:consequence]` emits explicit skill declarations
  and writes the `a2a do` block idempotently.

### Changed

- Security updates: `ash` 3.33.1 to 3.33.9 (EEF-CVE-2026-86338) and `mint` 1.10.0 to 1.10.1
  (EEF-CVE-2026-82672).
- `native/hddl_cli` repinned to ferroplan v0.28.0.
- The Semantic Work Envelope conserves the work-order subject through transport.

### Fixed

- GraphLaw WASM resolvers default to the vendored artifact instead of a developer-home
  path, which had made hosted CI fail 110 tests.
- `mix test.all` can no longer re-admit `:external_api`/`:benchmark` tests (which had fired
  real concurrent live-API calls).
- Test determinism fixes (measured-value assertion, shutdown and tmp-dir races, macOS
  `/var` symlink comparison).

## [26.9.21] - 2026-09-21

### Changed

- No functional source changes. Merged the round-2 GALL work from `release/v26.9.20` into
  `main` and removed fully merged branches. Full suite at the time: 58 doctests, 29
  properties, 2122 tests, 0 failures, 2 skipped.
- Point-in-time engineering records moved from `docs/` into `docs/archive/` (`jira/`,
  `reports/`, `session-history/`); live docs updated to match, and `docs/reference/index.md`
  gained the previously missing modules.
- `docs/reference/a2a-spec-version-mapping.md` is now part of the ExDoc extras and the
  README.

## [26.9.20] - 2026-09-20

### Added

- `AshA2A.Reconciliation.MapeK`, a Monitor/Analyze/Plan/Execute loop over shared knowledge.
- Structured-work-fabric message types under `lib/ash_a2a/gall/` (`Capability`,
  `Checkpoint`, `EvidenceReceipt`, `Fields`, `Message`, `WorkLease`).
- Per-method A2A JSON-RPC conformance tests over the real plug, and
  `docs/reference/a2a-spec-version-mapping.md`. One streaming test is skipped with a
  documented gap.
- A durable command-receipt seal binding a receipt to its exact command, capability and
  terminal-state identity (`lib/ash_a2a/gall/command_receipt.ex`).
- Process-intervention admission (`lib/ash_a2a/gall/process_intervention.ex`); the command
  fingerprint now also folds in the admitted candidate digest, closing a replay hole.
- 16 refusal codes classified so `classify/1` stays total.
- `CITATION.cff` and `REPRODUCE.md`.

### Changed

- SA2A profile identifiers moved to the 26.9.20 line.

## [26.9.18] - 2026-09-19

### Added

- A standing tail-latency tripwire for `CommandBus.run/4` under sustained load (late-half
  p99 within 3.0x early-half p99, zero errors).
- Three public vocabulary prefixes in `AshA2A.Semantic.Vocabulary`: `ssn`, `saref`, `qudt`.

### Fixed

- `RouterCounters` telemetry no longer cross-contaminates between concurrent instances on
  one node; `attach!/3` accepts `owner: pid` (default `:any`, unchanged).

## [26.9.17] - 2026-09-17

### Added

- Falsification-based conformance suite `AshA2A.Chicago` (`mix ash_a2a.chicago --profile
  core|logic|plan|do|strict`): 42 discoverable checks covering twelve gates, a mandatory
  counterexample corpus, benchmarks (`mix ash_a2a.chicago.bench`), and mutation testing
  (`mix ash_a2a.chicago.mutate`). It found and fixed capability substitution across agents,
  a claim-lease liveness gap after a crash, and a replay-coverage gap.
- `AshA2A.Authority.Grant` (`authorize/3`, `grant/3`, `granted?/3`, `policy/1`), a new
  `AshA2A.Authority.Broker.granted?/3` callback, and public
  `AshA2A.Authority.grant_token_id/2`.
- Real distributed-node, Oban, state-machine and failure-injection tests; benchmarks for all
  ten benchmark categories; stress and soak tests (sustained throughput, six-node
  concurrency, resource ceiling).
- `authority_broker_children/0`: configuring `AshA2A.Authority.Broker.Ekv` alone is now
  enough; the application starts the backing store.
- `docs/explanation/v26.9.17-commandbus-scale.md` measuring the `Ekv` receipt store and
  broker against the in-memory ones (a durability-versus-latency trade, not a pure win).
- Documentation: README rewrite, corrected Getting Started, new reference pages (DSL,
  configuration, telemetry, mix tasks, endpoint contract), message-lifecycle explanation,
  and `SECURITY.md`; `docs/` is shipped in the Hex package.

### Changed

- **Migration required.** `config :ash_a2a, :authority_policy` defaults to `:broker`
  (fail-closed); `config :ash_a2a, :authority_broker` selects the broker. With no broker
  configured, every `:change`/`:external_do` dispatch is refused with `:authority_required`
  and a warning names the missing configuration. The previous behavior remains available
  as `:transport_verified_grants_capability`, which logs a warning. See
  `docs/how-to/authenticate-agent-requests.md`.

### Fixed

- `HddlSolver` temp paths are unique across VMs (they collided between peer nodes).
- Semantic IR admission seal: remaining unsealed admission paths now mint a real seal, and
  new refusal codes are classified.
- `Semantic.Peer.admit_candidate/2` requires a parse-stage witness, and the shipped test
  worker verifies live authority before actuating.
- The README documents the one-time native build needed before `mix test`.

### Security

- **Breaking, fail-closed.** The default `AshA2A.Agent` dispatch path no longer lets any
  transport-authenticated caller hold authority for every skill. Authority now requires a
  standing grant from the configured broker; authentication alone confers none.
  `:observe` skills are unaffected and replay detection is preserved.

## [26.9.16] - 2026-09-16

No curated entry was cut for this release at the time; see the git history (conformance
suite work, canonical graph identity, RDF serialization gates, GraphLaw engine work).

## [26.9.15] - 2026-09-15

No curated entry was cut for this release at the time; see the git history.

## [26.9.14] - 2026-09-14

### Added

- `AshA2A.ReceiptStore.Ekv`, an on-disk receipt store (auto-wired when configured), and a
  `:durable` receipt standing for stores that persist.
- Typed per-skill arguments in the capability index, derived from Ash action arguments.
- `AshA2A.SemanticSubject`, binding command and receipt identity to a semantic graph digest.
- Opt-in semantic-request surface (`a2a do semantic_requests true end` plus per-message
  `semantic_request` metadata) and receipt-driven replanning for continuations.
- Real integrations: `AshA2A.Delivery.Oban`, `AshA2A.TaskLifecycle` (AshStateMachine),
  `AshA2A.Reactor.CommandWorkflow`, DurableServer restart, distributed peer nodes, Group,
  FLAME and ash_r2rml, and a real `ash_oban` scheduled-action fixture.
- The architecture verifier grew from 4 to 9 checks.

### Changed

- Architecture documentation corrected for the real ecosystem dependencies.

### Fixed

- Dispatch through `CommandBus` fired two OCEL events for one action; it now fires one.
- `mix ash_a2a.install` merges into an existing `extensions:` list instead of duplicating.
- The FLAME test now exercises the real path instead of passing vacuously.
- The opt-in `:external_api` test suite is runnable end to end (timeouts raised for
  rate-limited live calls).

### Known limitations

- DurableServer cross-node rehome is unexercised; only single-node restart is proven.
- A resource author can explicitly declare `consequence: :observe` on a mutating action;
  this is an intentional source-level escape hatch.

## [26.9.13] - 2026-09-13

### Added

- Semantic closed-loop pipeline (`AshA2A.Semantic.*`, `AshA2A.Planning.SemanticSynthesis`):
  text to admitted IR, ontology, planning IR, candidate plan, and an execution package.
- `AshA2A.Skill.consequence` (`:observe`, `:change`, `:external_do`, `:unknown`), computed
  at compile time with an explicit override. Unclassified capabilities are refused
  (`:consequence_unclassified`).

### Changed

- `CommandBus` is now on the default `AshA2A.Agent` dispatch path for every
  `:change`/`:external_do` skill. A client retry replays instead of re-executing, and a
  same-id retry with different content is a `:command_conflict`. `:read` and `:observe`
  skills stay on the direct path.
- `AshA2A.Telemetry.OcelForwarder.attach!/0` is called at application start.
- Skill lookup matches a selector against a skill's canonical `id` as well as its `name`.

### Fixed

- Update actions no longer fail when `accept` omits the primary key.
- `Authority.from_verified_identity/2` derives a deterministic token id, so authenticated
  retries no longer defeat replay detection.

## [26.9.12] - 2026-09-12

### Added

- Canonical capability projection: skills are derived from every public Ash action; `a2a do
  skill ... end` entries are overrides. Skill ids are `<Resource>.<action>`.
- Typed command and receipt machinery (`AshA2A.Command`, `AshA2A.Identity`,
  `AshA2A.CommandBus`, `AshA2A.ReceiptStore`) with idempotent replay and conflict refusal.
- Admission bridge (`AshA2A.Authority`, `AshA2A.Planning.candidate_fence/1`).
- Lifecycle and Reactor composition, adapter seams for Oban, Group, Presence, DurableServer
  and FLAME (each degrades to an `:unsupported` refusal without its library), and
  `AshA2A.SemanticProjection` for OCEL/RDF-shaped evidence.
- A Diataxis-structured documentation set under `docs/`.

### Fixed

- `AshA2A.Telemetry.OcelForwarder` forwards `relationships` again.

### Notes

- At this release the command-bus machinery was opt-in infrastructure, not yet the default
  dispatch path (see 26.9.13).

## [26.9.10] - 2026-09-10

### Added

- Spark DSL for defining A2A agents, actions and skills.
- Capability index with validator and agent-card builder.
- Dispatcher routing A2A requests to Ash actions, with task history and context threaded
  through.
- Installer for wiring `ash_a2a` into a host application.

### Fixed

- `AgentCard` `supported_interfaces` drift.
- Dispatcher `KeyError` on skill lookup.
- `__spark_metadata__` verification issues.
