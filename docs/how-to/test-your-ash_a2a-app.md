# How to test your ash_a2a app (and run this repo's own suite)

Two audiences, one page: **using** ash_a2a in your app (what the test
surface looks like), and **developing** this repo (prerequisites, commands,
known flakiness).

## Testing an app that uses ash_a2a

The cheapest high-information tests are direct dispatches — no process, no
HTTP:

```elixir
message = A2A.Message.new_user([A2A.Part.Data.new(%{"text" => "hi"})])
assert {:reply, [%A2A.Part.Data{data: %{result: ...}}]} =
         AshA2A.Dispatcher.dispatch(:my_skill, message, MyApp.Resource)
```

Assertions that pay for themselves:

- **Refusals**: unclassified skills refuse `:consequence_unclassified`;
  consequential skills without authority refuse `:authority_required`;
  replayed `command_id` with different content refuses
  `:command_conflict`. Assert the typed codes, not string output.
- **Trust boundary**: a message with `metadata["actor"]` set must not
  change `context.actor` — only `auth_identity` (the 4th/5th `dispatch/5`
  argument) does.
- **Compile-time**: declaring `skill(:x, :nonexistent_action)` fails
  compilation with `:REFUSED_ACTION_NOT_FOUND` — a compile-test (or just
  compiling your fixtures in `test/support`) is the guard.

For agent-process tests, start modules directly
(`MyApp.Agent.start_link([])`) rather than a second `A2A.AgentSupervisor`
(the library's own application already runs one under global names — a
duplicate raises `:already_started`). For plug-level tests,
`test/ash_a2a_plug_agent_card_test.exs` and
`test/ash_a2a_plug_auth_test.exs` in this repo are copyable patterns
(`Plug.Test`-driven, real `A2A.Plug` pipeline).

## Running this repo's own suite

### One-time native prerequisites

```sh
cd native/hddl_cli && cargo build --release --locked && cd -
```

- **Required.** `hddl_cli` is the real FOND/HTN planner integration;
  dozens of tests shell out to it. Missing binary → real test *failures*
  (`:hddl_cli_not_built`), never silent skips — do not mistake that for a
  code regression.
- Optional: `cd native/graphlaw_host && cargo build --release --locked`
  backs GraphLaw runtime B; CI does **not** build it, and the one test
  that needs it reports a named skip when absent.

### Postgres

The Oban delivery qualification tests need a real Postgres 16 reachable at
`localhost:55432` (db/user/password `postgres`, per `config/test.exs`):

```sh
docker run -d --name ash-a2a-pg -p 55432:5432 -e POSTGRES_PASSWORD=postgres postgres:16
```

Without it those tests fail in `setup_all` — 8 tests on a clean run.

### Commands

```sh
mix test                      # everyday work
mix test --max-cases 6       # canonical full-suite invocation
```

`--max-cases 6` is the number the suite is actually run with: it spawns
real `:peer` BEAM nodes and OS subprocesses, and higher parallelism trips
`:eaddrinuse` port-bind races. Tags: `:benchmark` and `:external_api` are
excluded by default (`test/test_helper.exs`); `:graphlaw` tests
self-exclude with a printed reason when the node/wasm prerequisites are
missing. Opt in explicitly:

```sh
mix test test/ash_a2a/chicago/stress/sustained_throughput_test.exs --include benchmark
```

### What's in the suite

~2086 tests plus 58 doctests and 29 properties: unit/DSL tests, real-Plug
HTTP tests, property/fuzz (StreamData), Oban-on-real-Postgres integration,
multinode `:peer` tests, the SA2A conformance court (dual real WASM/JS
runtimes over `priv/sa2a_conformance/`), and ~45 Chicago conformance
courts under `test/ash_a2a/chicago/`. The three CI-gate mix tasks
(`ash_a2a.verify_architecture`, `verify_adapters`, `verify_conformance`)
are also exercisable directly — see the
[mix tasks reference](../reference/mix-tasks.md).

### Known flakiness (honest inventory)

As of v26.9.17, repeated full runs show 1–2 failures in *different* tests
each run: `AshA2A.SemanticRefusalTest`'s `:hddl_solve_error` mapping check,
and an `:eaddrinuse` port-bind race under parallel execution. Both are
documented pre-existing in the CHANGELOG. Triage rule: re-run the single
file; if it passes in isolation, it's one of these, not your change.

### Mirroring CI

`.github/workflows/ci.yml` = ubuntu, OTP 28.0 / Elixir 1.19.0, Postgres 16
service on 55432, Rust 1.97.1 building `hddl_cli`, then
`mix format --check-formatted` → `mix compile --warnings-as-errors` →
`mix test`. Note CI's OTP 28 vs local `.tool-versions`/Docker OTP 27.2.4
split. `bin/ci-local.sh` runs ci.yml via `act`; on Apple Silicon it is a
disclosed-broken convenience (OTP 28 arm64 needs `libcrypto.so.1.1`) —
hosted Actions is the authoritative signal. The swarm/k8s workflow
(`swarm-test.yml`, manual dispatch) has its own README section in `k8s/`.
