# AshA2A

[![Hex Version](https://img.shields.io/hexpm/v/ash_a2a.svg)](https://hex.pm/packages/ash_a2a)
[![HexDocs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/ash_a2a/)
[![CI](https://github.com/seanchatmangpt/ash_a2a/actions/workflows/ci.yml/badge.svg)](https://github.com/seanchatmangpt/ash_a2a/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A `Spark.Dsl.Extension` that exposes `Ash.Resource`/`Ash.Domain` actions as
[A2A protocol](https://github.com/a2aproject/A2A) agent skills, with the
wire codec hosted in-repo as `AshA2A.Protocol.*` (ported from
[a2a-elixir](https://github.com/actioncard/a2a-elixir) 0.3.0, Apache-2.0 —
see `lib/ash_a2a/protocol/NOTICE`) over JSON-RPC 2.0/HTTP with SSE
streaming.

> **Naming**: the library and module prefix is **AshA2A**, the Hex package
> is `ash_a2a`, and **SA2A** is the internal project codename used by the
> RFCs (`docs/rfc/`) and the conformance courts (`docs/explanation/`).

Every **public** Ash action on an extended resource or domain is projected
into a verified capability index — no declaration required. An optional
`a2a do skill ... end` block adds A2A-only metadata overrides, and the
compiled index:

- builds a real `AshA2A.Protocol.AgentCard` (`AshA2A.Info.agent_card/2`) advertising each
  exposed skill,
- fails closed at compile time (`AshA2A.Verify`) if a skill override names a
  nonexistent action (`:REFUSED_ACTION_NOT_FOUND`) or duplicates a skill
  name (`:REFUSED_DUPLICATE_SKILL_NAME`),
- and dispatches an inbound `AshA2A.Protocol.Message` to the right Ash action
  (`AshA2A.Dispatcher.dispatch/6`; arities `/3`–`/5` remain valid via
  defaults), either as a bare function call or
  through a real supervised `AshA2A.Protocol.Agent` process (`AshA2A.Agent`) — routing
  consequence-bearing skills (`:change`/`:external_do`) through the
  receipted `AshA2A.CommandBus` with authority admission and replay-safe
  receipts,
- and carries the HILT work-order binding plane (`AshA2A.Hilt.WorkOrder`):
  `bind_command/2` places the work order's content-addressed identity into
  command metadata for `CommandBus` to verify before admission, and the
  carried `graph_digest` is pinned against the executing command's semantic
  subject (`checkpoint_graph_digest/2`) — drift refuses `:stale_graph_identity`.

Around that core, the v1.0 surfaces ship in the same package:

- **HTTP+JSON binding** — `AshA2A.Transport.HTTPJSON` serves the A2A v1.0
  spec's native REST shape (§5.3): `POST /message:send`,
  `GET /tasks/{id}`, `POST /tasks/{id}:cancel`, plus the §8.2 well-known
  agent card, with the same owner-scoped auth as the JSON-RPC plug.
- **gRPC binding** — `AshA2A.Transport.GRPC.Server` serves the canonical
  `lf.a2a.v1.A2AService` proto over HTTP/2: 9 unary RPCs plus the
  server-streaming `SendStreamingMessage`/`SubscribeToTask` (pumping the
  same per-task event log as SSE), routed through the same dispatch
  layer as the HTTP binding. The proto is vendored at
  `priv/proto/a2a.proto` with a SHA-256 provenance header and the full
  `protoc` regeneration recipe in that header.
- **Signed agent cards** — `AshA2A.Protocol.CardSigning` signs a card's
  `signatures` JWS entries and verifies each against the JCS
  canonicalization of the card payload (`CardSigning.verify/3`).
- **Discovery caching** — `AshA2A.Protocol.CardCache.fetch/2` implements
  A2A §8.6 client caching: `ETag`/`If-None-Match` revalidation, a
  persistent on-disk cache, and stale fallback when revalidation fails.
- **Compile-time skill verification** — `AshA2A.Verifiers.VerifySkills`
  and `AshA2A.Verify` fail compilation closed on bad projections
  (`:REFUSED_ACTION_NOT_FOUND`, `:REFUSED_ACTION_NOT_PUBLIC`,
  `:REFUSED_DUPLICATE_SKILL_NAME`).
- **Domain-level agent configuration** — `AshA2A.Domain` declares agent
  identity, transport placement and the security envelope once per
  `Ash.Domain` (`agent` / `transport` / `security` blocks, read back
  through `AshA2A.Domain.Info`).
- **JSON-Schema skill schemas** — `AshA2A.Schema` derives JSON Schema for
  a skill's inputs; `AshA2A.Protocol.Extensions.Schema` projects one
  `urn:sa2a:extension:schema:v1` card extension advertising every
  advertised skill's typed input contract.
- **Executor and typed errors** — `AshA2A.Executor.execute/3` is the
  verified-identity-to-Ash-action ingress pipeline;
  `AshA2A.ToA2AError.to_a2a_error/2` maps a failed Ash outcome onto an
  A2A error envelope by protocol dispatch, never string matching.
- **Durable async dispatch** — `AshA2A.Providers.PPlan` is the
  ash_pplan-backed durability provider, mapping ash_pplan runs onto A2A
  task states for async / multi-turn skills.

## Requirements

- Elixir `~> 1.19` (developed and tested on Elixir 1.20.4 / OTP 29.1.1; CI
  installs exactly `.tool-versions` via `erlef/setup-beam` with
  `version-type: strict`, and the swarm Docker image pins the same pair).
- Ash `~> 3.0`.
- No Rust toolchain is needed to **use** the published package. Rust is only
  needed to build the native HDDL/FOND planner when developing this repo or
  when you use the deterministic planning path — the binary is not shipped
  on Hex, so point `config :ash_a2a, :hddl_cli_path` at your own build (see
  [Configuration](docs/reference/configuration.md)).

## Installation

```elixir
def deps do
  [
    {:ash_a2a, "~> 26.10.3"}
  ]
end
```

There is no separate wire-protocol dependency to pin: the codec ships
inside `ash_a2a` as the `AshA2A.Protocol.*` modules, so call them directly
whenever your own code needs protocol-level types.

`mix ash_a2a.install` (an Igniter task) wires the extension into an
existing project; see `Mix.Tasks.AshA2a.Install`.

## Usage

Declare the DSL on a resource (or domain):

```elixir
defmodule MyApp.Echo do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:message, :string, public?: true)
  end

  actions do
    defaults([:read])
  end
end

defmodule MyApp.Domain do
  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(MyApp.Echo)
  end
end
```

Public actions are exposed with no `a2a` block at all; `a2a do
skill(:echo, :read) end` is an optional override (rename, describe, tag,
exclude, or classify). `AshA2A.Transformers.BuildCapabilityIndex` compiles
the residual overrides and `AshA2A.Verify` checks the projection fail-closed
after compilation.

Dispatch a message directly (no process):

```elixir
message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

{:reply, [%AshA2A.Protocol.Part.Data{data: %{results: []}}]} =
  AshA2A.Dispatcher.dispatch(:echo, message, MyApp.Echo)
```

`dispatch/6` takes further `history`, `auth_identity`, and `opts` arguments
(`history`/`auth_identity` default to `nil`-able values, `opts` to `[]` —
e.g. `:resolved_skill` carries the exact resolved skill through a
`CommandBus` re-dispatch, fixing multi-resource namesake
`:capability_mismatch` refusals). `auth_identity` is the trust boundary: with the
default `nil`, `context.actor`/`context.tenant` resolve to `nil` and
dispatch fails closed for anything your Ash policies gate on identity —
identity only ever arrives from transport-verified auth
(`AshA2A.Protocol.Plug.Auth`), never from message metadata. See
[Authenticate inbound A2A requests](docs/how-to/authenticate-agent-requests.md).

To boot supervised agent processes, serve them over HTTP (agent card +
JSON-RPC + SSE), and drive them with `AshA2A.Protocol.Client`, continue with the
[Getting Started tutorial](docs/tutorials/getting-started.md); for the exact
wire contract, see the
[A2A endpoint reference](docs/reference/a2a-endpoint-contract.md). On top of
the base `AshA2A.Protocol.Plug`, the library ships its own
`AshA2A.A2ATransport.Plug` — a drop-in wrapper implementing the methods the
base plug refuses: supervised `message/stream` fan-out with
`tasks/resubscribe` replay, push-notification config RPCs with signed
webhook delivery, and the authenticated extended card (same reference).

## Local development setup

Running this repo's own `mix test` requires one native Rust CLI binary to be
built first. CI (`.github/workflows/ci.yml`) builds it automatically (pinned
Rust 1.97.1); a local clone does not, so this is a real, one-time manual
step:

```sh
cd native/hddl_cli && cargo build --release --locked && cd -
```

- `native/hddl_cli` is the sole integration surface for the real FOND/HTN
  planner (`ferroplan`) — dozens of tests (deterministic HDDL synthesis,
  the FreedomGym facilitator fixture, request-router phase dispatch,
  Chicago qualification courts) invoke this binary as a subprocess and
  raise a clear, actionable error (`hddl_cli_not_built`) if it is missing —
  never a silent skip. Without it, `mix test` reports real test *failures*
  (not skips), which is easy to mistake for a code regression.
- `native/graphlaw_host` (optional, NOT built by CI) backs the GraphLaw
  WASM runtime B; if left unbuilt, the one test that needs it reports a
  named, correctly-handled skip rather than a failure.
- Postgres 16 on `localhost:55432` (user/password `postgres`, db
  `ash_a2a_test`, per `config/test.exs`) is needed by the real Oban
  delivery qualification tests.
- `mix test` (no args) is the fast-iteration default — it excludes the
  `:serial`-tagged tail (see the how-to guide below). The canonical
  full-suite invocation, and what CI runs, is `mix test.all --max-cases 6`
  (the suite spawns `:peer` nodes and subprocesses; higher parallelism
  trips port-bind races). Known-flaky tests are documented in the
  [CHANGELOG](CHANGELOG.md).

Full detail: [Testing ash_a2a (your app and this
repo)](docs/how-to/test-your-ash_a2a-app.md). Both `target/` directories are
gitignored build artifacts and are never committed.

## Documentation

This project follows the [Diataxis](https://diataxis.fr/) documentation
framework: tutorials for learning, how-to guides for specific tasks,
reference for lookup, and explanation for understanding. It is published on
[HexDocs](https://hexdocs.pm/ash_a2a/) and buildable locally with `mix docs`.

- **Tutorials** — [Getting Started](docs/tutorials/getting-started.md): a
  complete, end-to-end walkthrough from resource declaration through direct
  dispatch, a supervised agent process, and serving the agent over HTTP.
- **How-to guides**:
  - [Authenticate inbound A2A requests](docs/how-to/authenticate-agent-requests.md)
    — wire `AshA2A.Protocol.Plug.Auth` so a verified credential becomes
    `context.actor`/`context.tenant`, and grants — not authentication —
    decide consequential authority.
  - [Verify authority on async (Oban) paths](docs/how-to/verify-authority-on-async-paths.md)
    — re-verify grants in your own Oban workers with
    `ObanAuthority.verify_live!/3` so a revoked grant cannot actuate from a
    stale queue payload.
  - [Observe dispatch with OCEL](docs/how-to/observe-dispatch-with-ocel.md)
    — forward every dispatch as an OCEL v2 event to a process-mining
    ingest endpoint.
  - [Use role-based LLM resolution](docs/how-to/use-role-based-llm-resolution.md)
    — resolve LLM-backed actions through abstract roles instead of
    hardcoded provider strings.
  - [Enable semantic requests](docs/how-to/enable-semantic-requests.md) —
    opt a resource and caller into the semantic-compilation pipeline
    (`AshA2A.Semantic.Compiler`).
  - [Test your ash_a2a app](docs/how-to/test-your-ash_a2a-app.md) — run
    commands, native prerequisites, test taxonomy, known flakiness.
  - [Test governed actions](docs/how-to/test-governed-actions.md) — dispatch
    through the real CommandBus with an in-process broker and store, no mocks.
  - [Migrate legacy to strict](docs/how-to/migrate-legacy-to-strict.md) — the
    seven behavior changes, what breaks, and the fix for each.
- **Reference**:
  - [Module index](docs/reference/index.md)
  - [DSL reference](docs/reference/dsl.md) — the `a2a` section, `skill`
    entity, `hddl_operator`, and `semantic_requests` gate.
  - [Configuration](docs/reference/configuration.md) — every application
    config key and environment variable the library reads.
  - [Telemetry events](docs/reference/telemetry.md) — the event catalog
    with payloads.
  - [Mix tasks](docs/reference/mix-tasks.md) — the 15 shipped tasks.
  - [A2A endpoint contract](docs/reference/a2a-endpoint-contract.md) —
    served HTTP surface: agent card, JSON-RPC methods, error codes,
    streaming, auth.
  - [A2A spec version mapping](docs/reference/a2a-spec-version-mapping.md)
    — which A2A protocol spec version this library targets and how its
    JSON-RPC methods map onto it.
- **Explanation**:
  - [Architecture](docs/explanation/architecture.md) — the capability
    projection, admission/receipt layers, adapters, and consequence
    semantics.
  - [Message lifecycle](docs/explanation/message-lifecycle.md) — one
    request end to end, from wire to receipt.
  - [Canonical graph identity](docs/explanation/canonical-graph-identity.md)
    and [GraphLaw WASM integration](docs/explanation/graphlaw-wasm-integration.md).
- **Control plane & conformance** (shipped with the repo): [C2 certificate
  model](docs/reference/c2-certificate.md),
  [C2 wire interop](docs/reference/c2-wire-interop.md) (external
  authority/actuator projects, AuthZEN PDP policy evidence),
  [conformance claim](docs/reference/conformance-claim.md) and
  [profiles](docs/reference/conformance-profiles.md),
  [C2 compromise court](docs/reference/c2-compromise-court.md) (repo-only),
  [GALL closure ownership](docs/explanation/closure-implementations.md) (repo-only),
  the [approver app](docs/how-to/approver-apps.md) (repo-only),
  and the [release path](docs/how-to/release.md) (repo-only).

### Internal evidence and reports (not user documentation)

These artifacts are deliberately published with the repository but are
point-in-time engineering records, not guides. As of v26.9.31 the audit-era
records live under `docs/archive/`, grouped by kind:

- `docs/archive/reports/` — measured evidence: the v26.9.17 hardening/
  benchmark/stress pass (`chicago-benchmark-report.md`,
  `v26.9.17-{stress-report,hardening-audit,commandbus-scale}.md`,
  `sa2a-v26-9-17-{capability-coverage-sweep,hddl-reachability-analysis}.md`,
  referenced from the CHANGELOG), the `partisan-integration-investigation.md`
  spike note, and the security-posture reports gathered against the `k8s/`
  swarm manifests (`AIRGAP_READINESS_REPORT.md`, `ENTERPRISE_READINESS_REPORT.md`,
  `SSP_CONTROL_APPENDIX.md`; kind-cluster scope, 2026-09-15; explicitly not
  an ATO).
- `docs/archive/jira/` — RFC-style tickets, checkpoints, and ARD/PRD pairs
  from v26.9.11 through v26.9.18's development.
- `docs/archive/session-history/` — `MANUFACTURING_RECEIPT.md` and
  `litho.docs/`, internal session history and manufacturing records.
- `DOCS_AUDIT_v26.9.21.md` (repo root) — the accounting of this
  documentation audit itself: every file kept/updated/archived, and why.
- `docs/explanation/chicago-conformance-court.md` — what the RFC-SA2A-002
  conformance court is (kept in place: a durable explanation, not a
  point-in-time record).
- `docs/rfc/` — RFC-SA2A-001–007 (Proposed Standard status; kept in place —
  001/002 date from v26.9.16, 003–007 from v26.9.28, plus the
  `adoption/SPIFFE_ABSORPTION.md` record and the v26.9.26 ABB/SBB
  implementation notes).
- `research/` — kept in place, outside `docs/archive/`.

## Security

Identity is a trust boundary: `actor`/`tenant` only ever come from
transport-verified `AshA2A.Protocol.Plug.Auth` output, and consequential
(`:change`/`:external_do`) skills additionally require a standing grant from
`AshA2A.Authority.Grant` — authentication alone never confers authority
(RFC-SA2A-001 S29). Neither shipped broker (`InMemory`, `Ekv`) is
Sybil-resistant; bring your own identity system for production. Optional
absorbed boundaries extend that identity system: SPIFFE workload-attested
identities (`AshA2A.SPIFFE.*`) and OpenID AuthZEN PDP policy evidence
(`AshA2A.AuthZEN.*`) bind external decisions in as evidence — never as
authority. See [the authentication how-to](docs/how-to/authenticate-agent-requests.md)
and [SECURITY.md](SECURITY.md).

## Status

Versioning is calendar-based (`26.9.x`); `~> 26.9` pins within the 26.9
series. Semantic Versioning is intended after 1.0. See the
[CHANGELOG](CHANGELOG.md) — note that `main` routinely runs ahead of the
latest published Hex release.

## License

MIT — see [LICENSE](LICENSE).
