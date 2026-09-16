# Partisan Integration Investigation (v26.9.16) — BLOCKED at dependency resolution

Status: **BLOCKED**. Real `mix deps.get` dependency resolution fails before any
compile, start, join, or message-send step is reachable. This document records
the real evidence for that status; no success is claimed anywhere below.

## Charter

An earlier requirements synthesis in this session named
[Partisan](https://github.com/lasp-lang/partisan) (Meiklejohn et al., "Partisan:
Scaling Byzantine Fault-Tolerant Systems", building on the USENIX ATC 2019-era
work on distributed Erlang's clustering ceiling) as the real, published fix for
`:global`/`net_kernel` full-mesh clustering's documented ceiling of roughly
dozens to ~200 nodes. This investigation attempts a minimal real integration —
add the dependency, compile, start it, join two local nodes over its overlay,
send one message — and reports the real outcome, including a real BLOCKED
outcome if that is what happens.

## Real host facts (this session)

- Elixir `1.19.5` (compiled with Erlang/OTP 28)
- Erlang/OTP `28` (erts-16.2)
- rebar3 `3.27.0` on Erlang/OTP 28 Erts 16.2 (present at `/opt/homebrew/bin/rebar3`)
- Repo: `ash_a2a`, worktree `/tmp/ash_a2a-wt-partisan-investigate`,
  branch `feat/partisan-investigate-v26.9.16`, base `065bd80`

## Step 1 — real current Partisan package facts

`mix hex.info partisan` (run in this worktree, this session):

```
Partisan is a scalable and flexible, TCP-based membership system and distribution layer for the BEAM.

Config: {:partisan, "~> 6.2"}

Recent releases:
  6.2.0 (2026-08-27)
  6.1.0 (2026-08-14)
  6.0.0 (2026-07-31)
  5.0.3 (2025-08-14)
  ...

Licenses: Apache-2.0
```

Latest published version: **6.2.0** (2026-08-27). Per the Hex API
(`https://hex.pm/api/packages/partisan/releases/6.2.0`), its real declared,
non-optional dependency requirements are:

| dep | requirement |
|---|---|
| `backoff` | `1.1.6` (exact) |
| `opentelemetry_api` | `1.2.1` (exact) |
| `telemetry` | `~> 1.1.0` |
| `types` | `~> 0.1.8` |
| `uuid_erl` | `~> 2.0.5` |

Per `partisan.hexdocs.pm`, the real starting/joining/messaging API (README +
`partisan.html` moduledoc) is:

```erlang
%% start
partisan:start().
%% or, from an Elixir/OTP app:
application:ensure_all_started(partisan).

%% join a peer (shortcut for partisan_peer_service:join/1)
partisan:join(#{
  name => node_name,
  listen_addrs => [#{ip => IPAddress, port => Port}],
  channels => #{channel_name => #{parallelism => N}}
}).

%% send
partisan:cast_message(ServerRef, Message).   %% async, best-effort
partisan:send(Destination, Message).         %% best-effort
partisan:forward_message(ServerRef, Message). %% returns success/error status
```

Peer service manager and network config are set via `sys.config`
(`peer_service_manager`, `peer_ip`, `peer_port`, `channels`). This confirms
Partisan's real current API surface exists and is documented; the
investigation did not have to guess it. It was never reached in practice
because dependency resolution fails first (Step 2).

## Step 2 — real `mix deps.get` — BLOCKED

### Attempt 1: `{:partisan, "~> 6.2", only: :dev}` added to `mix.exs`

Real command: `mix deps.get`

Real, verbatim output:

```
Resolving Hex dependencies...
Resolution completed in 0.281s
Because "oban >= 2.20.0" depends on "telemetry ~> 1.3" and "partisan >= 5.0.0-rc.8" depends on "telemetry ~> 1.1.0", "oban >= 2.20.0" is incompatible with "partisan >= 5.0.0-rc.8".
And because "your app" depends on "oban ~> 2.24", "partisan >= 5.0.0-rc.8" is forbidden.
So, because "your app" depends on "partisan ~> 6.2", version solving failed.
** (Mix) Hex dependency resolution failed
```

Root cause, verified against the real Hex API (not inferred): every Partisan
`6.x` release checked (`6.0.0`, `6.2.0`) declares a hard, non-optional
`telemetry ~> 1.1.0` requirement (Elixir version-requirement semantics:
`>= 1.1.0, < 1.2.0`). This repo already requires `oban ~> 2.24`
(`mix.lock`: `oban` `2.24.1`, requiring `telemetry ~> 1.3`), and the repo's
already-locked `telemetry` is `1.4.2` (`mix.lock` line 82). `~> 1.1.0` and
`~> 1.3` (⇒ `1.3.x`–`1.x.x`, currently resolved to `1.4.2`) do not overlap.
This is a real, structural version conflict between Partisan's currently
published dependency pin and a dependency this repo already requires — not a
transient resolver hiccup.

### Attempt 2 (diagnostic-only, not committed as a fix): force `{:telemetry, "~> 1.3", override: true}`

To measure how deep the conflict runs (not proposed as a real fix — forcing
Partisan onto a `telemetry` minor series its own `mix.exs` explicitly
excludes would be running its code against a version its maintainers didn't
declare support for), the same `mix deps.get` was re-run with an explicit
`telemetry` override.

Real, verbatim output:

```
Resolving Hex dependencies...
Resolution completed in 2.143s
Because "the lock" depends on "tesla 1.21.3" which depends on "opentelemetry_semantic_conventions ~> 1.27", "the lock" requires "opentelemetry_semantic_conventions ~> 1.27".
And because "opentelemetry_api >= 1.2.1 and < 1.3.2" depends on "opentelemetry_semantic_conventions ~> 0.2", "the lock" is incompatible with "opentelemetry_api >= 1.2.1 and < 1.3.2".
And because "partisan >= 5.0.0-beta.24" depends on "opentelemetry_api 1.2.1", "the lock" is incompatible with "partisan >= 5.0.0-beta.24".
And because "your app" depends on "the lock", "partisan >= 5.0.0-beta.24" is forbidden.
So, because "your app" depends on "partisan ~> 6.2", version solving failed.
** (Mix) Hex dependency resolution failed
```

A second, independent conflict layer: Partisan hard-pins `opentelemetry_api`
to the **exact** version `1.2.1` (no range), which itself requires
`opentelemetry_semantic_conventions ~> 0.2`. This repo's `tesla` (pulled in
transitively via the RDF stack — `json_ld`/`sparql_client`, dependencies of
`ash_r2rml`) requires `opentelemetry_semantic_conventions ~> 1.27`. Those two
`opentelemetry_semantic_conventions` requirements do not overlap either.

Both real resolver failures were confirmed **before** `mix.lock` was ever
mutated (`git diff mix.lock` was empty after both attempts) — Hex's resolver
fails closed and never writes a broken lock.

Resolving the second layer would require also overriding
`opentelemetry_api`/`opentelemetry_semantic_conventions`, at which point the
change is no longer "add one dependency" but "force Partisan's entire
telemetry/OpenTelemetry pin stack to run on versions its own `mix.exs`
excludes" — an unverified, unsafe path this investigation did not pursue
further, consistent with the charter's instruction not to fabricate success.

### Step 3/4 — not reached

Because dependency resolution never completes, `mix compile`, `partisan:start/0`,
a real two-node `partisan:join/1`, and a real `partisan:cast_message/2` or
`partisan:send/2` were never reached. No compile, start, join, or
message-passing claim is made for any of them.

## Real status: BLOCKED

**BLOCKED** — did not reach a running state. Exact real blocking error
(Attempt 1, the direct/minimal integration path): see the verbatim
`mix deps.get` output above (`"oban >= 2.20.0" depends on "telemetry ~> 1.3"`
vs. `"partisan >= 5.0.0-rc.8" depends on "telemetry ~> 1.1.0"` →
`** (Mix) Hex dependency resolution failed`).

## What would change this

- A future Partisan release relaxing `telemetry` to `~> 1.3`-compatible and
  `opentelemetry_api` to a `~> 1.27`-compatible `opentelemetry_semantic_conventions`
  chain would remove both conflicts found here — worth re-checking
  `mix hex.info partisan` for a version newer than `6.2.0` before re-attempting.
- Isolating Partisan in a separate, minimal OTP release/node (no `oban`, no
  `tesla`/RDF stack in the same dependency graph) would sidestep both
  conflicts, at the cost of no longer being a same-app integration into
  `ash_a2a` — this was out of scope for "minimal real integration in this
  repo" as chartered, but is a real, distinct alternative worth naming for
  the portfolio-level graph.

## See also

- `test/ash_a2a_partisan_integration_test.exs` — the intended real two-node
  join/message test, explicitly `@tag :skip`ped with this same blocking
  reason, so it documents the target shape without silently mocking Partisan
  away or claiming a pass it did not earn.
