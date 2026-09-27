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
  change `context.actor` — only `auth_identity` (an argument of
  `dispatch/6`) does.
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
mix test                      # fast-iteration default (~1400 tests, ~4 min)
mix test.all --max-cases 6    # full suite, what CI runs (~2122 tests, ~12-20 min)
mix test.serial               # just the excluded serial tail (96 files)
```

`mix test` excludes the `:serial` tag by default (96 files, `async: false`
for real shared-state reasons -- mostly a shared global `:telemetry`
observer used for stimulus attribution in the Chicago courts; see each
tagged file's own moduledoc, and `test/test_helper.exs`'s broker comment).
These files run strictly one-at-a-time regardless of `--max-cases` and
dominate full-suite wall clock (measured: ~240s for the fast lane vs.
~740-1300s for everything). `mix test.all` runs the complete suite exactly
as before this alias existed, and is what CI invokes.
`--max-cases 6` (only meaningful for `test.all`/`test.serial`, since the
fast lane doesn't include the files that need it) is the number the full
suite is actually run with: it spawns real `:peer` BEAM nodes and OS
subprocesses, and higher parallelism trips `:eaddrinuse` port-bind races.
Tags: `:benchmark` and `:external_api` are excluded from every command
above by default (`test/test_helper.exs`); `:graphlaw` tests self-exclude
with a printed reason when the node/wasm prerequisites are missing. Opt
into a benchmark explicitly:

```sh
mix test.all test/ash_a2a/chicago/stress/sustained_throughput_test.exs --include benchmark
```

#### Running the serial tail with more concurrency

The 96 `:serial` files split into two disjoint, independently-tagged
groups (never combine `--only`/`--exclude` for two different tags in one
invocation to approximate this split -- confirmed the hard way: ExUnit's
`--only` is a sole selector and silently ignores an `--exclude` for a
*different* tag in the same command, and `--include` for a broader tag
re-admits everything under it via OR-logic, not AND):

- `:serial_solo` (23 files) hold a real host-level shared resource across
  OS processes -- a fixed port, a real `:peer`/multinode spawn, the
  shared Postgres test database, the `hddl_cli` native subprocess. Run
  together, never sharded: `mix test.serial.solo`.
- `:serial_shard` (73 files) are serial only for real but VM-local shared
  state (the telemetry observer, the shared in-memory authority broker)
  -- eliminated entirely by running each shard as its own OS process.
  Native `mix test --partitions` support makes this safe: each partition
  is its own BEAM VM, so there is nothing left to race between shards.

```sh
# 4-way example; tune N to your machine, and always capture each
# shard's own PID -- never stop test runs by name/pattern, since other
# processes on a shared machine can share the "mix test" substring.
for i in 1 2 3 4; do
  MIX_TEST_PARTITION=$i mix test.serial.shard --partitions 4 &
done
wait
mix test.serial.solo
```

### What's in the suite

~2122 tests plus 58 doctests and 29 properties (`mix test.all`): unit/DSL
tests, real-Plug HTTP tests, property/fuzz (StreamData),
Oban-on-real-Postgres integration, multinode `:peer` tests, the SA2A
conformance court (dual real WASM/JS runtimes over
`priv/sa2a_conformance/`), and ~45 Chicago conformance courts under
`test/ash_a2a/chicago/`. `mix test` (the default) covers ~1400 of these,
excluding the 96-file `:serial` tail. The three CI-gate mix tasks
(`ash_a2a.verify_architecture`, `verify_adapters`, `verify_conformance`)
are also exercisable directly — see the
[mix tasks reference](../reference/mix-tasks.md).

### Known flakiness (honest inventory)

As of v26.9.21 (~2122 tests), repeated full runs show 0–2 failures in
*different* tests each run: `AshA2A.Chicago.Hardening.BoundsExhaustionTest`'s
"no self-grant" property, and occasionally
`AshA2A.CancelInflightTest` -- both `--max-cases 6` concurrency-timing
flakes, confirmed pre-existing by diffing the failing file against
`origin/main` (empty diff) and passing 3/3 in isolated single-file reruns.
Documented in the CHANGELOG's `[26.9.20]`/`[26.9.21]` entries. Triage rule:
re-run the single file; if it passes in isolation, it's one of these, not
your change.

### Mirroring CI

`.github/workflows/ci.yml` = ubuntu, OTP 28.0 / Elixir 1.19.0, Postgres 16
service on 55432, Rust 1.97.1 building `hddl_cli`, then
`mix format --check-formatted` → `mix compile --warnings-as-errors` →
`mix test`. Note CI's OTP 28 vs local `.tool-versions`/Docker OTP 27.2.4
split. `bin/ci-local.sh` runs ci.yml via `act`; on Apple Silicon it is a
disclosed-broken convenience (OTP 28 arm64 needs `libcrypto.so.1.1`) —
hosted Actions is the authoritative signal. The swarm/k8s workflow
(`swarm-test.yml`, manual dispatch) has its own README section in `k8s/`.
