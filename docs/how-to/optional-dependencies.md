# Optional dependencies

Status: UNVERIFIED. No Elixir toolchain was available when this was written; nothing here
has been compiled or run.

`oban`, `ash_oban`, `ash_state_machine`, `postgrex`, `flame`, `durable_server` and
`req_llm` are declared `optional: true` in `mix.exs`. A consumer may omit any of them.

| Dependency | Used by | Guard | Behaviour when absent |
|---|---|---|---|
| `oban` | `AshA2A.Delivery.Oban` | `Code.ensure_loaded?` plus `apply/3` | `available?/0` is false; `enqueue/3` returns an error |
| `flame` | `AshA2A.Execution.FLAME` | `Code.ensure_loaded?` plus `apply/3` | `{:error, {:unsupported, :flame}}` |
| `durable_server` | `AshA2A.Durability.DurableServer` | provider probe plus `apply/3` | `{:error, {:unsupported, :durable_server, fun, arity}}` |
| `ash_state_machine` | `AshA2A.TaskLifecycle` | `@compile {:no_warn_undefined, ...}` plus probe | `{:error, {:unsupported, :ash_state_machine}}` |
| `req_llm` | `AshA2A.Semantic.Compiler`, `AshA2A.Planning.SemanticSynthesis` | default generator probes `ReqLLM` | `{:error, {:unsupported, :req_llm}}`, surfaced as a typed refusal |
| `ash_oban`, `postgrex` | no reference in `lib/` | none needed | not applicable; `ash_oban` requires `postgrex` itself |

Audit finding: the only unguarded reference was the default `&ReqLLM.generate_object/4`
capture, which raised `UndefinedFunctionError` when `req_llm` was missing. It now goes through
a guarded `default_generate_object/4`. Injecting `:generate_object` is unchanged.

Tests: `test/ash_a2a/l18_optional_deps_test.exs` (UNVERIFIED). The absence assertions for
`req_llm` only run when that dependency is not loaded; the DurableServer one always runs, using
a nonexistent provider module.

Remaining: CI never compiles the library without these deps, so true compile-without
coverage is not proven. A matrix job with the optional deps removed would close it.
