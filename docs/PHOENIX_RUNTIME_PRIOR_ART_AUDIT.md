# Phoenix Runtime Prior-Art Audit

Closes issue #11: "Review DurableServer, Group, FLAME, Phoenix Presence, and
related current Phoenix runtime work before adding more local runtime code.
For each capability, record whether ash_a2a should reuse, compose, extend, or
leave it external, and keep only the irreducible A2A/Ash integration residue
in this repository."

This audit covers the four adapter modules issue #11 names by name, each
already real (present at `main`/`epoch/v26.9.15-semantic-subject` HEAD
`ceb7ac0`), against real underlying libraries, with real (non-mocked) test
coverage exercised as part of this audit.

## Shared irreducible residue across all four adapters

Before the per-subsystem rows: all four adapters share the same two-part
irreducible residue, so it is recorded once here instead of four times.

- `AshA2A.RuntimeReceipt` — the observed-provider-evidence struct
  (`receipt_id`, `provider`, `operation`, `subject`, `status`, `result`,
  `recorded_at`, `standing: :observed`, `metadata`). Every adapter wraps its
  provider call in `RuntimeReceipt.new/5` and never lets the provider's own
  return value flow to the caller unwrapped.
- `AshA2A.Identity` — typed `AgentID`/`TaskID`/`RuntimeID` construction, used
  by every adapter's `key/1` to turn a typed identity into the provider's
  stable string key (e.g. `"task:task-42"`).

Every adapter's moduledoc states the same non-negotiable boundary: provider
mutations produce `RuntimeReceipt` evidence only, and **never** confer Ash
domain state, A2A task/command completion, or authority. That boundary itself
is the irreducible product of this repo — no wrapped library expresses it,
because no wrapped library knows about Ash or A2A.

## AshA2A.Durability.DurableServer

- **File**: `lib/ash_a2a/durability/durable_server.ex` (105 lines)
- **Wraps**: the real `durable_server` hex package (`{:durable_server, "~>
  0.1.5"}`, `mix.exs:86`), specifically `DurableServer.Supervisor` (the
  `@default_provider`, overridable via
  `Application.get_env(:ash_a2a, :durable_server_provider, ...)`). Moduledoc:
  "Optional adapter for Phoenix `DurableServer` task runtimes... The provider
  defaults to `DurableServer.Supervisor`."
- **Classification**: **Reuse**. The module is a thin provider-substitution
  seam (`provider/0`, `available?/0`, `key/1`) plus five receipted
  operations (`ensure_task`, `lookup`, `rehome_task`, `cordon_task`,
  `uncordon_task`, `delete_task`) that all delegate via `apply/3` to whatever
  module `provider/0` resolves to. It adds no competing durability
  implementation of its own; a missing/unloaded provider fails closed with
  `{:error, {:unsupported, :durable_server, function, arity}}` rather than
  fabricating durability.
- **Real test coverage** (grep for `DurableServer` under `test/`):
  - `test/ash_a2a/durable_server_test.exs` — key derivation + fail-closed
    unsupported path.
  - `test/ash_a2a/durable_server_continuity_test.exs` — restart and
    node-loss fixtures (`AshA2A.Test.FakeDurableServerSupervisor`, a real
    hand-written `Agent`-backed implementation of the provider contract, not
    an interaction-verifying mock — used because the real cloud
    ObjectStore/S3-backed provider is not restart/node-loss-simulatable
    in-process; this is the named, load-bearing exception per this repo's
    Chicago-style testing discipline). Both tests assert real returned/looked
    -up state (generation counters, node placement, persisted `state` map),
    never call counts.
  - `test/ash_a2a_runtime_providers_integration_test.exs` — drives an
    **actual** `DurableServer.Supervisor` backed by the real
    `DurableServer.Backends.EKVStore` (the real `:ekv` local durable-KV
    engine), asserting a real spawned GenServer's `GenServer.call/2` replies
    and a real receipt shape.
  - `test/support/durable_server_fixture.ex` — `AshA2A.Test.DurableServerFixture`,
    `use DurableServer, vsn: 1` — a real `DurableServer`-behaviour GenServer,
    not a fake.
- **Verification run**: see Verification section below.
- **Current standing**: this module (`AshA2A.Durability.DurableServer`) itself
  is real, compiled, and passes its own real tests (see Verification below).
  Its sibling issue #8 tracks the **larger DurableServer-based runtime
  continuity feature stack** (PR #14,
  `v26.9.12/pr12-durable-qualification@da74f6ce`), which issue #8's own
  2026-09-13 comment records as:

  > "Implementation update: PR #14
  > (`v26.9.12/pr12-durable-qualification@da74f6ceafe08d84d91255a979b8668e4d5f788e`)
  > now adds the restart and node-loss qualification fixtures required
  > here... This issue remains open because the stack is still draft and
  > there is no exact-head Elixir compile/test execution receipt. Current
  > standing: `CANDIDATE / BUILD_UNVERIFIED`; not ALIVE."

  This audit does not re-derive or supersede that standing — issue #8 is the
  authoritative record for the PR2-PR14 stack's draft/BUILD_UNVERIFIED
  status. What this audit adds: the adapter module itself, at the HEAD this
  audit ran against (`ceb7ac0`, already merged to
  `epoch/v26.9.15-semantic-subject`, not part of the still-draft PR2-PR14
  stack), is real, compiles clean, and its own three test files pass for
  real — i.e. the *adapter* is ALIVE even while the *larger continuity
  feature stack* issue #8 tracks remains CANDIDATE/BUILD_UNVERIFIED.
- **Irreducible residue kept in ash_a2a**: `key/1` (typed `Identity` →
  DurableServer string key), the five receipted operation wrappers, the
  provider-substitution seam (`provider/0`/`available?/0`), and the
  fail-closed `{:unsupported, ...}` contract. **Delegated entirely** to
  `durable_server`: process supervision, storage-backend abstraction
  (S3/ObjectStore/EKV), state dump/load versioning, node placement, and
  restart/recovery mechanics.

## AshA2A.Topology.Group

- **File**: `lib/ash_a2a/topology/group.ex` (60 lines)
- **Wraps**: the real `group` hex package (`mix.lock: "group", "0.2.1"`,
  pulled in transitively — `deps/durable_server/mix.exs:43` declares
  `{:group, "~> 0.2.0"}` — not a direct `mix.exs` dep of ash_a2a itself, but
  resolvable and loaded because `durable_server` already requires it, which
  is why `Code.ensure_loaded?(Group)`/`available?/0` resolve true at
  runtime), a distributed process/topology registry. Moduledoc: "Optional
  adapter for the `Group` process/topology registry."
- **Classification**: **Reuse**. Same shape as the other three: `key/1`
  (typed identity/string/atom → registry key string), plus
  `register/unregister/join/leave` (receipted mutations) and `lookup/members`
  (unreceipted reads, since reads are "ephemeral observations" per the
  moduledoc). No local registry/topology logic is implemented — every
  operation delegates via `apply(Group, function, args)`.
- **Real test coverage**: `test/ash_a2a/group_topology_test.exs` — asserts
  real deterministic key derivation (`Group.key(Identity.agent("worker-1"))
  == "agent:worker-1"`) and the fail-closed unsupported path when the
  provider is unavailable. This is the narrowest of the four test files (no
  integration test exercising a live `Group` registry process exists in this
  repo, unlike DurableServer/Presence/FLAME which each also have an
  integration-level test against a real running provider).
- **Verification run**: see Verification section below.
- **Current standing**: compiles clean; its one real test file passes (see
  Verification below). No live-process integration test exists for `Group`
  the way `RuntimeProvidersIntegrationTest` covers DurableServer and
  Presence — the real gap this audit surfaces (see Conclusion).
- **Irreducible residue kept in ash_a2a**: `key/1` and the five receipted/
  unreceipted operation wrappers. **Delegated entirely** to `group`: the
  actual process registration/membership/group semantics.

## AshA2A.Topology.Presence

- **File**: `lib/ash_a2a/topology/presence.ex` (63 lines)
- **Wraps**: `Phoenix.Presence` (real dep, `{:phoenix, "~> 1.7"}` +
  `{:phoenix_pubsub, "~> 2.1"}`, `mix.exs:98-99`) — a **host-application**
  module the caller supplies (`presence_module` argument on every function),
  not a dependency this repo itself defines an implementation of. Moduledoc:
  "Adapter for a host application's `Phoenix.Presence` module... Presence is
  strictly ephemeral topology."
- **Classification**: **Reuse** (with the caveat that "reuse" here means
  reusing the *host's* Presence module through a generic adapter, since
  `Phoenix.Presence` is designed to be `use`d per-application, not called
  directly as a library singleton). `available?/1` checks the caller-supplied
  module exports `track/4` and `list/1`; `list/track/update/untrack` all
  delegate via `apply/3`.
- **Real test coverage**:
  - `test/ash_a2a/presence_topology_test.exs` — key derivation + fail-closed
    unsupported path against a genuinely missing module
    (`AshA2A.Test.MissingPresence`).
  - `test/ash_a2a_runtime_providers_integration_test.exs` — drives an actual
    `Phoenix.Presence`-based module (`AshA2A.Test.PresenceFixture`, `use
    Phoenix.Presence, otp_app: :ash_a2a, pubsub_server:
    AshA2A.Test.PubSubFixture`) backed by a real `Phoenix.PubSub` process,
    asserting real `track`/`list`/`untrack` state (`Map.has_key?(present,
    key)`), not call counts.
  - `test/support/presence_fixture.ex` — the real `Phoenix.Presence`
    implementation backing the integration test above.
- **Verification run**: see Verification section below.
- **Current standing**: compiles clean; all three real test files pass (see
  Verification below).
- **Irreducible residue kept in ash_a2a**: `key/1`, `available?/1`'s
  export-shape check, and the four receipted/unreceipted operation wrappers.
  **Delegated entirely** to `Phoenix.Presence`/`Phoenix.PubSub`: CRDT-based
  presence tracking, diff broadcasting, and the host module's own topic/PubSub
  wiring.

## AshA2A.Execution.FLAME

- **File**: `lib/ash_a2a/execution/flame.ex` (56 lines)
- **Wraps**: the real `flame` hex package (`{:flame, "~> 0.5"}`,
  `mix.exs:85`), specifically `FLAME.call/3`. Moduledoc: "Optional FLAME
  placement adapter for receipted AshA2A commands. FLAME chooses where the
  closure runs; it never gains independent capability, authority, or
  dispatch semantics."
- **Classification**: **Compose** (not plain reuse) — this is the one
  subsystem of the four that composes the external library with this repo's
  own `AshA2A.CommandBus` rather than just wrapping a provider call: `run/5`
  places a closure via `FLAME.call/3` whose body is
  `AshA2A.CommandBus.run(command, message, resource_or_domain, bus_opts)`, so
  the same admission/replay/receipt fence applies regardless of which BEAM
  node the closure actually executes on.
- **Real test coverage** (grep for `FLAME` under `test/`, excluding the
  doc-comment-only mention in `test/ash_a2a_agent_command_bus_test.exs:66`):
  - `test/ash_a2a/flame_placement_test.exs` — two tests: a fail-closed path
    (guarded by `unless FLAME.available?()`, does not execute its body in
    this environment since FLAME is available), and **the real happy-path
    test named in this task's own rationale**: starts a genuine
    `Elixir.FLAME.Pool` (FLAME's own documented `FLAME.LocalBackend`, "useful
    for development and testing") and a real `ReceiptStore.Memory`, then
    asserts a real completed `AshA2A.Receipt` (status `:completed`, a real
    reply, non-replayed on first call) and a real `AshA2A.RuntimeReceipt`
    placement record, then re-runs the identical command and asserts the
    *second* call returns the *same* `receipt_id` with `replayed?: true` —
    proving the first call really executed and committed rather than
    returning a placeholder.
  - `test/ash_a2a_runtime_providers_integration_test.exs` — a narrower
    `available?/0` check against the real `flame` dependency.
- **Verification run**: see Verification section below.
- **Current standing**: ALIVE — compiles clean, and its real local-pool
  happy-path test (not just an `available?/0` smoke check) passes with real
  asserted state (see Verification below). This is the most heavily
  qualified of the four subsystems: it is the only one with a same-file
  comment explaining exactly why the happy path could finally be tested for
  real (FLAME's own `LocalBackend` needs no external infrastructure), and the
  only one whose test proves receipt-store replay semantics end-to-end
  through a real placement.
- **Irreducible residue kept in ash_a2a**: `available?/0`, `run/5`'s closure
  composition (wrapping `AshA2A.CommandBus.run/4` inside the `FLAME.call/3`
  closure) and its exception/`catch` normalization into `{:error, ...}`
  tuples, plus the dual-receipt shape (`%{receipt: ..., placement: ...}`)
  that keeps CommandBus's execution receipt and FLAME's placement receipt
  distinct. **Delegated entirely** to `flame`: actual node/pool placement,
  backend selection (Local/FLY/etc.), and closure serialization/transport.

## Verification

Real `mix test` output for each subsystem's test files, run at this audit's
worktree HEAD (`nextcap/issue-11-phoenix-runtime-prior-art-audit`, branched
from `epoch/v26.9.15-semantic-subject` at `ceb7ac0`):

Chicago-style mocking check (zero matches required, zero found):

```
$ grep -rn "Mox\|:meck\|Mock(" test/
(no output -- grep exit 1, zero matches)
```

`AshA2A.Durability.DurableServer`:

```
$ mix test test/ash_a2a/durable_server_test.exs test/ash_a2a/durable_server_continuity_test.exs
Running ExUnit with seed: 74889, max_cases: 32
Excluding tags: [:external_api]

....
Finished in 0.08 seconds (0.07s async, 0.01s sync)
4 tests, 0 failures
EXIT: 0
```

`AshA2A.Topology.Group`:

```
$ mix test test/ash_a2a/group_topology_test.exs
Running ExUnit with seed: 345460, max_cases: 32
Excluding tags: [:external_api]

..
Finished in 0.02 seconds (0.02s async, 0.00s sync)
2 tests, 0 failures
EXIT: 0
```

`AshA2A.Topology.Presence`:

```
$ mix test test/ash_a2a/presence_topology_test.exs
Running ExUnit with seed: 860746, max_cases: 32
Excluding tags: [:external_api]

..
Finished in 0.02 seconds (0.02s async, 0.00s sync)
2 tests, 0 failures
EXIT: 0
```

`AshA2A.Execution.FLAME`:

```
$ mix test test/ash_a2a/flame_placement_test.exs
Running ExUnit with seed: 7963, max_cases: 32
Excluding tags: [:external_api]

..
Finished in 0.1 seconds (0.1s async, 0.00s sync)
2 tests, 0 failures
EXIT: 0
```

Cross-subsystem integration test (real `DurableServer.Supervisor` +
`DurableServer.Backends.EKVStore`, real `Phoenix.Presence` + `Phoenix.PubSub`,
real `flame` `available?/0`):

```
$ mix test test/ash_a2a_runtime_providers_integration_test.exs
Finished in 0.6 seconds (0.00s async, 0.6s sync)
6 tests, 0 failures
EXIT: 0
```

`mix format --check-formatted`: exit 0, no output (clean).

`mix compile --warnings-as-errors`: exit 0. (Emits type-checker warnings from
three *dependencies* -- `sweet_xml`, `ggen_igniter` -- which are pre-existing
upstream warnings surfaced by Elixir 1.19's set-theoretic type checker on
`deps/`, not from any `ash_a2a` source file; they do not fail the
`--warnings-as-errors` gate because that flag only escalates warnings in this
project's own compiled units. `ash_a2a` itself: "Compiling 55 files (.ex) /
Generated ash_a2a app", clean.)

Full suite (`mix test`, no file filter):

```
Finished in 5.0 seconds (1.4s async, 3.5s sync)
3 doctests, 3 properties, 264 tests, 0 failures (7 excluded)
EXIT: 0
```

All verification commands above were run for real, at this worktree's HEAD
(`ceb7ac0`, branch `nextcap/issue-11-phoenix-runtime-prior-art-audit`), in
this audit session -- not copied from a prior claim.

## Conclusion

All four subsystems named in issue #11 are already at **Reuse/Compose**
classification with real, non-mocked test coverage — no subsystem needed a
new local reimplementation, and none should get one. The one real gap this
audit surfaces: **`AshA2A.Topology.Group` has no live-process integration
test** (unlike DurableServer, Presence, and FLAME, which each have one
exercising a real running provider in addition to the key-derivation/
fail-closed unit test). This is a real, narrow gap, not a blocker to closing
this audit issue — issue #11 asked only for the reuse/compose/extend/
leave-external record, not new test authorship, and no new Elixir test code
was in scope for this task.

## See Also

- Issue #11 — this audit's charter.
- Issue #8 — DurableServer runtime-continuity feature stack (PR2-PR14),
  `CANDIDATE / BUILD_UNVERIFIED` as of its own 2026-09-13 comment; this
  audit's DurableServer row defers to that record rather than re-deriving it.
- `lib/ash_a2a/runtime_receipt.ex` — the shared receipt contract all four
  adapters use.
- `lib/ash_a2a/identity.ex` — the shared typed-identity contract all four
  adapters' `key/1` functions use.
