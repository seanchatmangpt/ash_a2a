# ash_a2a#27 CI Failure: Format, Environment, and One Real Defect

Stream `ash-a2a-format` (ERRC Eliminate). Subject: PR #27 in `seanchatmangpt/ash_a2a`, head
`fabric/dfcm-semantic-work-identity-conservation`, base `feat/v26.9.18-semantic-work-fabric`.
Work base for this stream: `2730c9b47a26219a2111a8273ead8f0a5f69c6ec` (main at start).

## Summary

The "formatting" failure named in the ERRC backlog was already fixed on the PR branch by
`8d61f46`. What still fails PR #27 is the `mix test` step: 107 failures, of which 103 are one
class (seven wasm resolvers defaulting to a developer-home path), 3 are an environmental class
(sibling checkouts), and 1 is a real defect in the PR's own code.

Correction (repair pass, supersedes the first version of this document): the 103 were first
classified as "engine unreachable on the hosted runner" and hidden behind `:graphlaw_engine`.
That premise was false. The praxis-graphlaw wasm is vendored and git-tracked at
`priv/graphlaw/praxis_graphlaw.wasm` (sha256 `187688d9...c0f28`, equal to
`priv/graphlaw/MANIFEST.json`, to `priv/sa2a_conformance/MANIFEST.json`, and to the praxis
build at `crates/praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm`). The 103 failures
were the resolver defaults, not an absent engine. They are now fixed at the root: the seven
resolvers default to `AshA2A.GraphLaw.wasm_path/0`, the 103 tests run on hosted CI, and
`:graphlaw_engine` remains only as a named, printed fallback for a truly missing artifact or a
missing `node`.

## PR #27 check history (read-only `gh`)

| Run | Head | Failed step |
|---|---|---|
| 35494963236 | `73d37ec1` | `mix format --check-formatted` |
| 35495398861 | `d104ca5c` | `mix format --check-formatted` |
| 35495411665 | `1dca1728` | `mix format --check-formatted` |
| 35539819401 | `8d61f46e` | `mix test` (format and compile steps: success) |

Files the format fix touched (`gh pr view 27 --json files`): `lib/ash_a2a/chicago/bench.ex` and
`test/ash_a2a/chicago/real_collaborators_test.exs`. On the base tree used here,
`mix format --check-formatted` exits 0.

## Classification of the 107 `mix test` failures on run 35539819401

| Class | Count | Cause | Disposition |
|---|---|---|---|
| Resolver default | 103 | Seven resolvers default to a `~/praxis` wasm path; the identical wasm is vendored | fixed: default is the vendored artifact |
| Sibling repos absent | 3 | Topology court checks 11 repos under `/Users/sac` | `:sibling_repos` |
| Real defect | 1 | Six `Semantic.WorkEnvelope` refusal codes have no S42 class | fixed on PR head |

The six unmapped codes (`AshA2A.SemanticRefusalTest`, "every refusal code found on disk is
explicitly mapped"): `refused_capability_contradiction`, `refused_graph_identity_mismatch`,
`refused_invalid_semantic_field`, `refused_missing_semantic_field`,
`refused_semantic_work_descriptor`, `refused_unbound_checkpoint`. They come from
`lib/ash_a2a/semantic/work_envelope.ex` (present on the PR head, absent on main), which is why
that test passes on main and fails on the PR.

## What changed on this branch (`errc/ash-a2a-format`)

Commit `8815f5b` (environment exclusions):

- `test/test_helper.exs`: accumulates excluded tags. `:graphlaw` behavior is unchanged. New
  `:graphlaw_engine` is excluded when any of the seven resolved wasm paths or `node` is
  missing; new `:sibling_repos` is excluded when any of the 11 topology repos has no `.git`.
  Each exclusion prints its reason on stderr. Nothing is stubbed and nothing passes silently.
- 22 test files: `@tag`/`@moduletag` on exactly the tests that failed on the runner
  (`AdversarialInputTest` and `SemanticCrossPeerTest` are module-wide; the rest are per test).

Repair commit (root cause of the 103):

- Seven resolvers now fall back to `AshA2A.GraphLaw.wasm_path/0` instead of a developer-home
  path: `graph_law/wasm.ex`, `graph_law/wasm_driver.ex`, `graph_law/runtime.ex`,
  `sa2a/graphlaw.ex`, `semantic/graph_law/wasm.ex`, `semantic/graph_law_bridge.ex`,
  `semantic/root_manifest/engine_probe.ex`. Override precedence (opts, app env, env vars) is
  unchanged. `AshA2A.GraphLaw`, `WasmtimeRuntime` and `WasmexHost` already defaulted to `priv/`.
- With that default, `:graphlaw_engine` excludes nothing on any checkout that has `node` on
  `PATH`; the tag and the `test_helper.exs` block remain as the fallback for a missing
  artifact or `node` (UNVERIFIED: the hosted ubuntu runner's `node` version against the wasm
  host; `ubuntu-latest` preinstalls Node and `ci.yml` does not pin it). `:sibling_repos`
  stays: those 3 tests are legitimately unrunnable on a hosted runner.
- Guards: `test/ash_a2a/chicago/wasm_default_resolution_test.exs` (each resolver, no override,
  resolves to a real file whose sha256 equals the MANIFEST pin; 7 of 9 fail on base
  `2730c9b`), and `test/ash_a2a/chicago/falsifier_wasm_default_reachability_test.exs`
  (no `lib/` wasm default under a developer home; failed at `55753a5`).
- `test/ash_a2a_sa2a_corpus_test.exs`: the pin test joined `/Users/sac/praxis` with a manifest
  path that already starts with `praxis/`, a path that never existed, so it always took its
  "not checkable here" branch and never compared a digest. It now compares the vendored wasm's
  sha256 and byte size to the corpus manifest on every checkout.
- `AshA2A.Chicago.Fixtures.GraphlawEngine.stop_host/1`: a TOCTOU race (host linked to the test
  process dies between `Process.whereis/1` and `GenServer.stop/3`) failed
  `GraphlawEngineTest` "every recorded case re-runs..." once in a full run under load
  (`** (exit) no process`); it passes 3 of 3 in isolation. `stop_pid/1` now treats "already
  gone" as success; guard: `test/ash_a2a/chicago/graphlaw_engine_stop_host_test.exs`.

## Evidence

- Base `2730c9b`, this tree, real environment, before the change: `mix compile
  --warnings-as-errors` exit 0, `mix format --check-formatted` exit 0, full `mix test`: 58
  doctests, 29 properties, 2122 tests, 0 failures, 2 skipped (18 excluded).
- Hosted-CI simulation of the original `8815f5b` state (wasm paths pointed at a missing file
  through the app config and all five env vars, run over the 23 failing files). SUPERSEDED by
  the repair below: it measured the exclusion, and the exclusion was the wrong fix.
  - forced-include (`--include graphlaw_engine --include sibling_repos`): 316 tests,
    103 failures; the failing set equals the CI set minus the 4 not reproducible locally
    (3 sibling-repo tests and the real defect), with 0 failures CI did not have.
  - as committed: 4 doctests, 213 tests, 0 failures, 3 skipped (122 excluded).
- Repair, hosted-runner simulation (`f31df40`): a clean `git clone` (tracked files only) with
  `deps`/`_build` cloned, run under macOS `sandbox-exec` with
  `(deny file-read* (subpath "/Users/sac/praxis"))` so `File.exists?` on the praxis wasm is
  `false` while the vendored wasm is `true` (verified from Elixir in the sandbox):
  - Same three files at base `2730c9b` (`graph_law_wasm_test`, `semantic_admission_pipeline_test`,
    `graphlaw_engine_test`): 20 tests, 1 failure, 10 skipped, 27 excluded, with
    `[sa2a] EXCLUDING :graphlaw live-engine tests -- wasm_not_built (wasm: /Users/sac/praxis/...)`.
    At `f31df40`: 47 tests, 0 failures, no `EXCLUDING` line.
  - All 24 tagged files plus the new guards, no sandbox: 4 doctests, 368 tests, 0 failures, no
    `EXCLUDING` line. With the sandbox: 329 of those pass and 6 fail plus 33 invalid (all
    in the executable-identity probe, `emulator_sha256 => nil`, which needs process
    introspection); the identical 6 failures and 33 invalid reproduce under
    `sandbox-exec -p '(version 1)(allow default)'` with no deny rule, so they are a sandbox
    artifact and not a reachability finding.
- Sibling-repo simulation (`:chicago_topology_root` pointed at a missing directory): forced
  include gives 19 tests, 3 failures; as committed gives 16 tests, 0 failures (3 excluded).
- The temporary simulation config was reverted before commit; `git diff -- config/test.exs`
  is empty.
- After the change, real environment, full `mix test` (host load average about 190 from other
  sessions): 58 doctests, 29 properties, 2122 tests, 4 failures, 2 skipped (18 excluded). No
  `EXCLUDING` line was printed, so the new tags exclude nothing where the collaborators exist.
  The 4 failures are load-sensitive and none is a tagged test:
  - `CancelInflightTest` and `ActuationClaimLeaseTest`: pass when rerun in isolation.
  - `AshA2AArchitectureVerifierTest` (60000 ms timeout) and `LibclusterHordePocTest` (5000 ms
    `assert_receive`): fail identically on the untouched base `2730c9b` under the same load
    (pre-existing under load, not introduced by this change).

## Merge guidance for PR #27

1. The test-exclusion commit `8815f5b` applies to the PR head (`git apply --check` of its
   `test/` diff onto `488ae22` succeeded): only two of the tagged files differ between the PR
   head and this base (`envelope_negotiation_transport_test.exs`, `sa2a_conformance_test.exs`),
   in unrelated version-string hunks. The repair commit `f31df40` supersedes its premise:
   the `lib/` + `test/` diff `2730c9b..f31df40` also `git apply --check`s cleanly onto
   `488ae22` (worktree `/Users/sac/ash_a2a-wt2/pr27`, no change made). `f31df40` edits
   `test/test_helper.exs` and the tagged files that `8815f5b` introduced, so take them in
   order and together; `8815f5b` alone would hide 103 real-engine tests behind a false
   premise, and the falsifier `5ece126` fails until `f31df40` lands.
2. The refusal-class commit is `488ae22` on `errc/ash-a2a-pr27-refusal-classes` (cut from
   `8d61f46e`); it is only meaningful on the PR branch. With it,
   `test/ash_a2a/semantic_refusal_test.exs` (21 tests, including "every refusal code found on
   disk is explicitly mapped") and `test/ash_a2a_semantic_work_envelope_test.exs` pass, and
   `mix compile --warnings-as-errors` and `mix format --check-formatted` exit 0.
3. All are candidates; none was pushed. Merge order on the PR branch: `488ae22` first
   (real defect), then `8815f5b` (environment), `5ece126` (falsifier), `f31df40` (root-cause
   repair).

## Not configured

`mix credo` is not part of this repository (`credo` is not in `mix.exs` deps and there is no
`.credo.exs`; CI runs format, compile with warnings as errors, then `mix test`).

## See Also

- `docs/streams/ash-a2a-external-do.md` for the external-do override findings.
- `test/test_helper.exs` for the exclusion contract.
- `.github/workflows/ci.yml` for the hosted-CI step order.
