# ash_a2a — Manufacturing Receipt

Repo: `/Users/sac/ash_a2a` (git repo, `main`). This receipt originally described
the initial commit; §3/§4 below were refreshed at HEAD `473f9f7` (was stale at
`e351130`) with a real `mix test`/`mix compile` re-run — §1/§2's file-list and
generated-vs-handwritten numbers still describe the original commit's diff and
have not been re-diffed against `473f9f7`.
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

21 doctests + 3 properties + 17 tests = 41 total, 0 failures, 0 mocks. Chicago-style compliance check
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
4. **`ggen sync run` template verification (PRD §3.8.4) — still not
   executed, genuinely open.** Per §2 above, the EEx template under
   `priv/ggen/ash_a2a/templates/` has never been run through `ggen sync`; the
   previously-reported `/workspace` path-resolution blocker in the installed
   `ggen` binary was not re-tested this session. **This run's own
   generation-vs-handwrite gap is exactly this item**: every module the test
   suite actually exercises was hand-written directly, not produced by the
   ggen pipeline the PRD designs around — the pipeline exists only as
   unexecuted input material (ontology + query + template).
5. **Dispatcher type-warning — RESOLVED as of HEAD `473f9f7`.** `mix compile
   --force` at HEAD now compiles 13 files with **no** typing-violation
   warning on `AshA2A.Dispatcher.fetch_skill/2` (verified by re-running the
   compile in this pass; output was `Compiling 13 files (.ex)` /
   `Generated ash_a2a app`, no warnings). This receipt was not present in
   this session's own diff, so the fix landed via a parallel agent's commit
   between `e351130` and `473f9f7` — stated here from direct re-verification
   of the compiler output, not from reading that agent's diff; treat as
   confirmed-resolved unless the CrossCheck phase finds contrary evidence.

## 5. Unresolved review findings

No code-review pass (`code-review` skill) was run in this session against this
diff — this receipt's "unresolved findings" are limited to the type-warning in §3/§4
item 5, which is a self-discovered compiler finding, not a reviewer finding. No
external review findings exist yet to report as unresolved.
