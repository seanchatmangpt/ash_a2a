# How to run mutation testing over the security surface

## Overview

`mix muzak.sec` runs muzak mutation testing scoped to the security-critical
auth/verify surface: `AshA2A.Transport.Plug`,
`AshA2A.Protocol.Plug.{Auth, SecurityValidators, JWTVerifier}`,
`AshA2A.Protocol.CardSigning`, and `AshA2A.Protocol.PushNotificationSender.HTTP`.

The oracle is the real ExUnit suite (the honest full court). A full run is
hours (muzak restarts the suite per mutant); bound it with `--mutations N` or
scope the oracle with `MUZAK_TEST_PATHS` (below).

## Prerequisites

- Elixir 1.19 / OTP 28. muzak 1.1.1 (2022-12, unmaintained) needs the three
  Elixir-1.19 compat shims that `.muzak.exs` compiles over the dep at run
  time (formatter, runner, config); the hex dep stays stock — nothing is
  vendored into the package.
- `MIX_ENV=test mix deps.get` (muzak is `only: :test, runtime: false`).

## Running

```console
# Bounded sample (recommended): N mutants over the 6 security modules
MIX_ENV=test mix muzak.sec --mutations 10

# Per-module profile: mutate exactly one module (add a profile key to
# .muzak.exs, e.g. auth: [same opts with a single-file filter])
MIX_ENV=test mix muzak.sec --profile auth --mutations 20
```

## Oracle scoping (known limitation)

muzak requires a `test_helper.exs` inside every `:test_paths` directory and
couples ExUnit's `only` to the mutation-target string, so today the only
working oracle is the full `test/` tree (default). Scoping to just the
matching security courts (via the `MUZAK_TEST_PATHS` hook in `mix.exs`) needs
one of: a guarded per-directory helper in each scoped dir, or a fourth shim
(patched `Muzak.Config`) — both attempted and deferred: the per-dir helper
must be idempotent under muzak's helper re-require loop, and the runtime
`Muzak.Config` reload proved nondeterministic under muzak's app-restart
cycle. Until then, run bounded (`--mutations N`).

## Reading the report

muzak's summary line `N run - M mutations survived` gives the kill rate. Run
with `DEBUG=1` to print each mutant's ORIGINAL/MUTATION diff. A mutant that
`failed to compile` is counted as killed by muzak — sanity-check with DEBUG=1
that kills are real test failures, not compile fallout. Survivors need
classification: equivalent mutant (no observable behavior change) vs real gap
(add a killing assertion).
