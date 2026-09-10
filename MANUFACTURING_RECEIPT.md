# ash_a2a — Manufacturing Receipt

Repo: `/Users/sac/ash_a2a` (git repo, `main`). This receipt originally described
the initial commit; §3/§4 were refreshed at HEAD `473f9f7` (was stale at
`e351130`), then refreshed again at HEAD `4f1a79e` (dispatcher skill-lookup
fix, AgentCard proto-drift hardening, version bump to `26.9.10`), and now once
more at the current HEAD landing the Zach-Daniel-review finish-all pass for
v26.9.10 (Spark DSL correctness fixes, dispatcher hardening, `priv/ggen`
namespace fix + legacy disclosure, `capability_index.ex` decomposition,
test-hardening) — real `mix test`/`mix compile` re-run below: **21 doctests, 3
properties, 48 tests, 0 failures**. §1/§2's file-list and generated-vs-
handwritten numbers still describe the original commit's diff and have not
been re-diffed against the current HEAD — read as history for that section
specifically, not current file inventory.
Charter/source of truth: `~/ggen-marketplace/docs/explanation/ash-a2a-prd-ard.md`.

## 1. Files this run (real numbers, `git diff --cached --stat`)

```
 .formatter.exs                                     |   4 +
 .gitignore                                         |  24 ++
 README.md                                          |  21 ++
 config/config.exs                                  |   7 +
 config/test.exs                                    |   3 +
 lib/ash_a2a.ex                                     |  32 +++
 lib/ash_a2a/application.ex                         |  12 +
 lib/ash_a2a/capability_index.ex                    | 124 ++++++++++
 lib/ash_a2a/context_resolver.ex                    |  54 +++++
 lib/ash_a2a/dispatcher.ex                          | 251 +++++++++++++++++++++
 lib/ash_a2a/dsl.ex                                 |  50 ++++
 lib/ash_a2a/execution_context.ex                   |  22 ++
 lib/ash_a2a/info.ex                                |  99 ++++++++
 lib/ash_a2a/skill.ex                               |  23 ++
 lib/ash_a2a/transformers/build_capability_index.ex |  88 ++++++++
 lib/ash_a2a/verify.ex                              |  43 ++++
 lib/mix/tasks/ash_a2a.install.ex                   | 157 +++++++++++++
 mix.exs                                            |  35 +++
 mix.lock                                           |  43 ++++
 priv/ggen/ash_a2a/ontology.ttl                     | 208 +++++++++++++++++
 priv/ggen/ash_a2a/queries/spec.rq                  |  58 +++++
 priv/ggen/ash_a2a/templates/extension.ex.eex       | 101 +++++++++
 test/ash_a2a_test.exs                              |  33 +++
 test/support/fixture.ex                            |  45 ++++
 test/test_helper.exs                               |   1 +
 25 files changed, 1538 insertions(+)
```

`lib/` total: 1444 lines across 9 modules + 1 mix task (verified via `wc -l`).

## 2. Generated vs. hand-written (honest split)

**100% of `lib/` and `test/` is hand-written.** There is no `generated/` (or
equivalent ggen-output) directory anywhere in this repo — confirmed by
`find . -name generated` returning nothing outside `deps/`/`_build/`.

What exists under `priv/ggen/ash_a2a/` (`ontology.ttl`, `queries/spec.rq`,
`templates/extension.ex.eex`) is **hand-authored ggen *input* material** (an RDF
ontology describing the DSL shape, a SPARQL query, and an EEx template modeled on
`ash-extension-core-pack`'s `aex:` vocabulary per PRD §3.1–3.4) — not output ggen
ever actually rendered. `ggen sync run` was **not executed** against this pack in
this run. This matches the PRD's own flagged risk (§1.6, §3.8 item 4): the
`ggen_igniter` v26.9 EEx-port pipeline for this pack was UNVERIFIED before this
session, and it remains UNVERIFIED now — the template exists as a design artifact,
not as a proven code-generation path. Every real, compiling module in `lib/` was
written directly against the PRD's cited upstream shapes (`ash_ai`'s
`resource_tools.ex`/`dsl.ex`/`tool/execution.ex`, `ash_r2rml`'s
`resource.ex` persist/verify pattern), not derived from a ggen render.

## 3. Verify-phase output (real, pasted, not paraphrased)

### `mix deps.get` — succeeded (abbreviated tail; full dep set resolved, including
`{:a2a, path: "/Users/sac/xaas/deps/a2a"}`, `ash ~> 3.0`, `igniter ~> 0.6`,
`ggen_igniter ~> 26.9`).

### `mix format --check-formatted` (after `mix format` was run to fix 3 unformatted files)

```
FMT_EXIT:0
```

(Before the fix, `test/support/fixture.ex`, `lib/ash_a2a/verify.ex`, and
`lib/ash_a2a/dsl.ex` were not formatter-clean; `mix format` was applied and
re-verified clean — see git history of this commit for the formatted state.)

### `mix compile --force`

```
Compiling 12 files (.ex)
    warning: the following clause will never match:

        {:error, _} = error

    because it attempts to match on the result of:

        AshA2A.Info.skill(resource_or_domain, to_skill_name(skill_name))

    which has type:

        dynamic(:error or {:ok, term()})

    typing violation found at:
    │
 80 │       {:error, _} = error -> error
    │                   ~
    │
    └─ lib/ash_a2a/dispatcher.ex:80:19: AshA2A.Dispatcher.fetch_skill/2

Generated ash_a2a app
```

Compiles successfully. One real, unresolved Elixir-typechecker warning in
`AshA2A.Dispatcher.fetch_skill/2` (line 80): `AshA2A.Info.skill/2`'s inferred
return type is `dynamic(:error or {:ok, term()})`, so the `{:error, _} = error`
match clause is dead code per the type-checker — `Info.skill/2`'s spec needs
tightening to actually return `{:error, term()}` (not bare `:error`) for this
clause to be reachable, or the dead clause should be removed. Left as-is and
reported honestly rather than silently patched without re-deriving the intended
error contract.

### `mix test` (re-run against the current working tree, superseding both the
`e351130` and `473f9f7` runs below — the working tree now also includes a
concurrent agent's uncommitted `test/ash_a2a/capability_index_agent_card_shape_test.exs`)

```
Running ExUnit with seed: 568942, max_cases: 32

.........................................
Finished in 0.5 seconds (0.08s async, 0.4s sync)
21 doctests, 3 properties, 17 tests, 0 failures
```

21 doctests + 3 properties + 17 tests = 41 total, 0 failures, 0 mocks (as of HEAD
`4f1a79e`). **Re-verified at the current HEAD (v26.9.10 finish-all pass):
21 doctests + 3 properties + 48 tests = 72 total, 0 failures** — real `mix
test` output, not paraphrased. New tests cover dispatcher action-type
branches (`create`/`update`/`destroy`/generic `:action`), `to_reply/1`
error-class mapping, `pop_stream_flag/1` variants, `context_resolver.ex`
string-key fallback branches, and `AshA2A.Application.start/2`'s real
supervision tree. Chicago-style compliance check
(`grep -rn "Mock\|mox\|patch(" lib test`) returns only two doc-comment lines
stating the *absence* of mocking (`test/ash_a2a_test.exs:6`,
`test/support/fixture.ex:7`) — zero actual mock/stub/patch usage. Tests exercise a
real fixture Ash resource (`test/support/fixture.ex`) with real `a2a do skill
:echo, :read end`, compiled through the real `AshA2A` Spark extension, real
`AshA2A.Info`/`AshA2A.Dispatcher` — no `:a2a` runtime behavior stubbed.

## 4. Remaining open blockers (PRD §3.8, plus this run's own gap) — updated at HEAD `473f9f7`

1. **Proto conformance (PRD §3.8.1) — CONCRETIZED, not resolved.** This pass
   diffed `A2A.AgentCard.t()` (`~/xaas/deps/a2a/lib/a2a/agent_card.ex:16-76`)
   against `AgentCard` in `~/A2A/specification/a2a.proto:396-434` (`Next ID: 20`)
   field-by-field. Real, named drift found:
   - **`url`** — the Elixir struct declares a required top-level scalar
     `url: String.t()` (and `AshA2A.CapabilityIndex.build_agent_card/2`,
     `lib/ash_a2a/capability_index.ex:120`, always sets it, defaulting to
     `"http://localhost:4000"`). The proto `AgentCard` message has **no**
     top-level `url` field at all — field numbers 3/9/14/15/16 are explicitly
     `reserved` (removed), and the spec's replacement is the repeated
     `supported_interfaces` field (19), where each `AgentInterface`
     (`a2a.proto:374-388`) carries its own `url` + `protocol_binding` +
     `protocol_version`.
   - **`supported_interfaces`** — present in both the Elixir type (`t/0`
     field, defaults to `[]`) and the proto (field 19, `REQUIRED`,
     "Ordered list of supported interfaces. First entry is preferred."), but
     `build_agent_card/2` never populates it — no `:supported_interfaces` key
     is read from `opts` or assigned in the struct literal
     (`lib/ash_a2a/capability_index.ex:112-126`). Every card this library
     builds ships an empty list where the proto requires at least one entry.
   - **`security`** — Elixir represents this as
     `[%{String.t() => [String.t()]}]` (a bare list of scheme-name→scopes
     maps). The proto's equivalent is `security_requirements` (field 13,
     `repeated SecurityRequirement`) — a structured message type, not a bare
     map list, and a different field name than the Elixir key.
   - **`signatures`** — the proto has `repeated AgentCardSignature
     signatures = 17` ("JSON Web Signatures computed for this AgentCard").
     `A2A.AgentCard.t()` has no `signatures` field at all; nothing in this
     library reads, writes, or verifies signatures.
   - `name`, `description`, `version`, `security_schemes`, `skills`,
     `default_input_modes`/`default_output_modes` line up directly and are
     **not** part of this drift.
   No code was changed to close this gap this run — it is now a specific,
   field-level UNVERIFIED-with-citations finding, not the prior vague
   "no coupling was established" note.
2. **gRPC transport (PRD §3.8.2) — still absent, genuinely open.** `:a2a`
   0.2.0 has no gRPC support; none was added this run (out of v1 scope per
   PRD §1.3).
3. **`ex4pm` → `:a2a` dependency (PRD §3.8.3) — still not wired, genuinely
   open.** This repo depends on `:a2a` directly via a `path:` dependency to
   `/Users/sac/xaas/deps/a2a`; `ex4pm`'s own `mix.lock` was not touched or
   verified this run.
4. **`ggen sync run` template verification (PRD §3.8.4) — now actually
   executed; BLOCKED with a real, reproduced compile error, different from
   the previously-reported `/workspace` blocker.** This pass ran the real
   Elixir task (not the standalone Rust `ggen` binary — that binary was not
   invoked here, so the prior `/workspace` path-resolution blocker was not
   re-tested/reproduced in this form):

   ```
   $ mix ggen_igniter.sync \
       --ontology priv/ggen/ash_a2a/ontology.ttl \
       --query spec=priv/ggen/ash_a2a/queries/spec.rq \
       --template priv/ggen/ash_a2a/templates/extension.ex.eex \
       --out <scratch>/ash_a2a_rendered.ex \
       --dry-run

   warning: <%# is deprecated, use <%!-- or add a space between <% and # instead
   └─ nofile:1: (file)

   warning: <%# is deprecated, use <%!-- or add a space between <% and # instead
   └─ nofile:13: (file)

   error: undefined variable "assigns"
   └─ nofile:27

   ** (RuntimeError) ggen_igniter: reactor reconciliation failed (refused): %CompileError{file: "nofile", line: 0, description: "cannot compile file (errors have been logged)"}
       (ggen_igniter 26.9.8) lib/mix/tasks/ggen_igniter.sync.ex:1006: Mix.Tasks.GgenIgniter.Sync.dispatch_reactor_reconcile/2
       (ggen_igniter 26.9.8) lib/mix/tasks/ggen_igniter.sync.ex:756: Mix.Tasks.GgenIgniter.Sync.run_sync/3
       (ggen_igniter 26.9.8) lib/mix/tasks/ggen_igniter.sync.ex:199: Mix.Tasks.GgenIgniter.Sync."run (overridable 1)"/1
   ```

   Root cause, confirmed by inspection: line 27 of
   `templates/extension.ex.eex` (`defmodule <%= @skill_struct %> do`) uses
   `@`-assigns-style EEx variable access (the convention this template was
   authored under, mirroring `ash-extension-core-pack`'s Tera-to-EEx
   translation), but `ggen_igniter`'s `Render` module compiles/evaluates the
   template without binding an `assigns` map — its own render path expects
   plain-binding EEx (`<%= skill_struct %>` against `EEx.eval_string(...,
   [skill_struct: ...])`), not `Phoenix`-style `@skill_struct` access. This
   is a genuine template/runtime convention mismatch, not the `/workspace`
   path bug and not an installation problem — `mix ggen_igniter.sync --help`
   runs cleanly and the task is real and invokable; the query itself (fixed
   last pass) was never reached because compilation of the template fails
   first. Fixing it (rewriting the template's ~15 `@foo` references to plain
   bindings, or switching `ggen_igniter`'s render to `assigns`-based EEx) was
   not attempted this pass — out of scope for a verification-only task; this
   is the disclosed, concretely-reproduced open item going forward, no longer
   "never re-tested." Two real, separately-scoped fixes landed the prior
   pass and remain in place: (a) a
   genuine namespace mismatch bug between `queries/spec.rq` (was
   `PREFIX aex: <.../ash-extension-core#>`) and `ontology.ttl` (declares
   `@prefix ash_a2a: <.../ash-a2a#>`) meant the query could not bind against
   the ontology at all — fixed for real, `spec.rq` now uses `ash_a2a:` and
   the real predicate names `ontology.ttl` actually declares
   (`skillOf`/`nestedOf`, not a generic `sectionOf`/`entityOf`); (b) both
   `ontology.ttl` and `templates/extension.ex.eex` now carry an explicit
   legacy-disclosure comment stating plainly that this material predates and
   does not follow `ggen_igniter`'s admitted `GeneratorCapability` pattern
   (ontology fact + capability envelope -> composed `Igniter.Mix.Task` ->
   real Ash/Igniter generators) and must not be copied as an example for new
   `ggen_igniter` consumers. **This run's own generation-vs-handwrite gap
   remains real**: every module the test suite actually exercises is still
   hand-written, not produced by the ggen pipeline — but the input material
   is now internally consistent (query can bind) and honestly labeled
   (no longer silently presented as if it followed the admitted pattern).
   A full redesign to the admitted pattern is tracked as a follow-up in
   `~/ggen_igniter/docs/jira/`, not attempted in this pass.
5. **Dispatcher type-warning — RESOLVED as of HEAD `473f9f7`, then further
   hardened at `4f1a79e` and again this pass.** `mix compile --force` now
   compiles cleanly with **no** typing-violation warning on
   `AshA2A.Dispatcher.fetch_skill/2` — `Info.skill/2` genuinely returns
   `{:error, :skill_not_found}` (not a compiler-satisfied dead branch),
   verified by two real dispatch-path tests. This pass additionally found
   and fixed three real, adversarially-confirmed Spark-DSL-correctness bugs
   in the surrounding transformer/entity code (not the same bug, found by a
   Zach-Daniel-persona review): the `:skill` entity had no `identifier: :name`
   (so Spark's own structural duplicate-name rejection was bypassed in favor
   of a slower, later hand-rolled check — fixed, with a real test asserting
   Spark's own `Spark.Error.DslError` now fires); `BuildCapabilityIndex`'s
   `Enum.reduce/3` accumulator wasn't carried once an error occurred, so a
   *non-last* malformed skill crashed with a raw `FunctionClauseError`
   instead of a clean `DslError` — fixed with `Enum.reduce_while/3`; and
   `after?/1` unconditionally claimed a blanket "run after everything"
   ordering with no real data dependency — narrowed to `false` with a real
   test.
6. **Dispatcher hardening (this pass, new findings, all fixed).** A
   Zach-Daniel-persona review also found and fixed: the `TenantRequired`
   error carve-out in `to_reply/1` only matched read's
   `Ash.Error.Invalid.TenantRequired`/`NoPrimaryAction` structs, so
   create/update/destroy's generic tenant-enforcement error fell through to
   the wrong `:input_required` class; `fetch_record_for_update/3` hardcoded
   a literal `id`/`:id` key instead of resolving the resource's real primary
   key via `Ash.Resource.Info.primary_key/1` (breaking for any resource with
   a differently-named or composite primary key); every non-happy-path error
   class collapsed to the same generic `"failed"` wire status with
   `inspect()` text, discarding the class distinction the code computes;
   and `AshA2A.Dispatcher.dispatch/5` had no exception boundary, so an
   unrescued raise inside context resolution or the underlying Ash call
   would crash the entire agent GenServer, not just the one in-flight task.

## 5. Unresolved review findings

A Zach-Daniel-persona harsh review (Spark DSL correctness, Ash integration
correctness, A2A/Reactor protocol fidelity lenses) plus a companion 5-lens
refactor review both ran this pass, adversarially verified. Confirmed,
in-scope findings from both were fixed (§4 items 5-6 above; documentation
staleness in this receipt and
`~/ggen-marketplace/docs/explanation/ash-a2a-prd-ard.md` §3.8 item 5
corrected).

**`capability_index.ex` module decomposition — RESOLVED (follow-up pass).** A
first attempt landed mid-swarm but produced orphaned duplicate modules (never
wired as real delegates, no real call site referenced them) due to a
concurrent-edit race in that swarm; that attempt was reverted rather than
shipped half-done. It was then redone directly, carefully: `validate/1`
extracted to `AshA2A.CapabilityIndex.Validator`, `build_agent_card/2`
extracted to `AshA2A.CapabilityIndex.AgentCardBuilder`, with
`AshA2A.CapabilityIndex` kept as a real thin facade (`defdelegate`) so
existing call sites (`AshA2A.Verify`, `AshA2A.Info`) and the
`CapabilityIndex.skill()`/`refusal()` types they reference keep working
unchanged. Re-verified: `mix compile --warnings-as-errors` clean, `mix
format --check-formatted` clean, `mix test`: 21 doctests, 3 properties, 48
tests, 0 failures.

Explicitly **not** fixed this pass, tracked as open follow-ups rather than
silently dropped:
- A full redesign of `priv/ggen/ash_a2a/` to `ggen_igniter`'s admitted
  `GeneratorCapability` pattern (§4 item 4) — a real design decision, not a
  mechanical fix; the namespace bug and doctrine disclosure were fixed, the
  redesign itself was not attempted.
- Whether a real Ash/Igniter generator capability exists at all for authoring
  a `Spark.Dsl.Extension` — an open question the redesign above depends on.
- `gRPC` transport and `ex4pm` → `:a2a` dependency wiring (§4 items 2-3) —
  unchanged, genuinely out of this pass's scope.
