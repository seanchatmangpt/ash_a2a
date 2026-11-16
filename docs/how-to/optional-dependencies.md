# Optional dependencies

Status: verified locally (2026-11-16, Elixir 1.20.4 / OTP 29.1.1): the guard tests below pass
and `scripts/check_optional_deps.sh` ran all ten cases and exited 0 (see Compile matrix). Its CI
workflow has never run.

`oban`, `ash_oban`, `ash_state_machine`, `postgrex`, `flame`, `durable_server`, `req_llm`,
`bandit` and `simple_sat` are declared `optional: true` in `mix.exs`. A consumer may omit any
of them.

| Dependency | Used by | Guard | Behaviour when absent |
|---|---|---|---|
| `oban` | `AshA2A.Delivery.Oban` | `Code.ensure_loaded?` plus `apply/3` | `available?/0` is false; `enqueue/3` returns an error |
| `flame` | `AshA2A.Execution.FLAME` | `Code.ensure_loaded?` plus `apply/3` | `{:error, {:unsupported, :flame}}` |
| `durable_server` | `AshA2A.Durability.DurableServer` | provider probe plus `apply/3` | `{:error, {:unsupported, :durable_server, fun, arity}}` |
| `ash_state_machine` | `AshA2A.TaskLifecycle` | `@compile {:no_warn_undefined, ...}` plus probe | `{:error, {:unsupported, :ash_state_machine}}` |
| `req_llm` | `AshA2A.Semantic.Compiler`, `AshA2A.Planning.SemanticSynthesis` | default generator probes `ReqLLM` | `{:error, {:unsupported, :req_llm}}`, surfaced as a typed refusal |
| `ash_oban`, `postgrex` | no reference in `lib/` | none needed | not applicable; `ash_oban` requires `postgrex` itself |
| `bandit` | `AshA2A.Sim.*` (the simulation server, its resource, prover, surface and MCP modules) | each file is wrapped in `if Code.ensure_loaded?(Bandit)` | the modules do not exist; `mix ash_a2a.sim` stops with a message naming the dependency |
| `simple_sat` | Ash policy verification for `AshA2A.Sim.Note` | none in `lib/`; `mix ash_a2a.sim` checks for `SimpleSat` or `Picosat` | with Bandit but no SAT solver, Spark warns at compile time and the task stops with a message |

Audit finding: the only unguarded reference was the default `&ReqLLM.generate_object/4`
capture, which raised `UndefinedFunctionError` when `req_llm` was missing. It now goes through
a guarded `default_generate_object/4`. Injecting `:generate_object` is unchanged.

Tests: `mix test test/ash_a2a/l18_optional_deps_test.exs` (3 passed). The absence assertions for
`req_llm` only run when that dependency is not loaded; the DurableServer one always runs, using
a nonexistent provider module.

Consumer build with none of the optional dependencies added (a throwaway project whose only
dependency is `{:ash_a2a, path: ...}`, the script's first case, run by hand): `mix deps.get`,
`mix deps.compile ash_a2a --force` and `mix compile --warnings-as-errors` all exited 0. In that
build `Bandit`, `SimpleSat`, `Oban`, `FLAME` and `ReqLLM` are not loaded, no `AshA2A.Sim.*`
module exists and `AshA2A.Transport.Plug` loads. `ash_state_machine` and `postgrex` were still
resolved into that build's lock file, so their absence was not exercised. Compiling `ash_a2a`
there printed 43 compiler warnings (Elixir 1.20 type-checker findings such as "the following
clause will never match"); none names an optional dependency or a `Sim` module. Four mechanical
ones were fixed afterwards (an unused alias, two bitstring sizes, a type named `record/0`).

With the optional dependencies present, `MIX_ENV=dev mix compile` exits 0 and
`MIX_ENV=dev mix ash_a2a.sim --prove` passed every probe (221 of 221 when it was run).

## Compile matrix

`scripts/check_optional_deps.sh` builds a throwaway consumer project with a path dependency on
this repo, then runs `mix deps.get`, `mix deps.compile`, a forced `mix deps.compile ash_a2a`
and `mix compile --warnings-as-errors`. A case fails on a compile error, or when a compiler
warning printed while compiling `ash_a2a` names a module of an optional dependency (`Oban`,
`AshOban`, `AshStateMachine`, `Postgrex`, `FLAME`, `DurableServer`, `ReqLLM`, `Bandit`,
`SimpleSat`), which is how a missing guard shows up. Other compiler warnings are printed as a
count and do not fail the script. It runs once with none of the optional deps and once per
single optional dep. `.github/workflows/optional-deps.yml` runs it on push
and pull request. `test/optional_deps_matrix_test.exs` asserts the script's list equals the
`optional: true` deps in `mix.exs`.

Status: the script ran here on 2026-11-16 and exited 0 with `optional deps matrix: all cases
compiled` after ten cases (none, then `oban`, `ash_oban`, `ash_state_machine`, `postgrex`,
`flame`, `durable_server`, `req_llm`, `bandit`, `simple_sat`). No warning named an optional
dependency. Each case reported 40 to 43 other compiler warnings in `ash_a2a` (type-checker
findings; the count moved because `lib/` was being edited during the run). Two changes were
needed before it could pass: the script now builds the dependencies before it force-compiles
`ash_a2a` (it did not, so the first case stopped on `Plug.Conn is not loaded`), and its gate is
the optional-dependency check described above instead of "any warning".
`mix test test/optional_deps_matrix_test.exs` passes (3 passed), so the script's list equals
`mix.exs`.

UNVERIFIED: the workflow has never run in CI. Remaining: clear the other compiler warnings,
cover combinations of optional deps, and make the workflow a required check.
