# ash_a2a#27 CI Failure: Format, Environment, and One Real Defect

Stream `ash-a2a-format` (ERRC Eliminate). Subject: PR #27 in `seanchatmangpt/ash_a2a`, head
`fabric/dfcm-semantic-work-identity-conservation`, base `feat/v26.9.18-semantic-work-fabric`.
Work base for this stream: `2730c9b47a26219a2111a8273ead8f0a5f69c6ec` (main at start).

## Summary

The "formatting" failure named in the ERRC backlog was already fixed on the PR branch by
`8d61f46`. What still fails PR #27 is the `mix test` step: 107 failures, of which 103 are one
environmental class, 3 are a second environmental class, and 1 is a real defect in the PR's
own code. This stream removes the environmental classes (named, printed test exclusions) and
fixes the real defect on a branch cut from the PR head.

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
| Engine unreachable | 103 | Seven resolvers default to `~/praxis` wasm | `:graphlaw_engine` |
| Sibling repos absent | 3 | Topology court checks 11 repos under `/Users/sac` | `:sibling_repos` |
| Real defect | 1 | Six `Semantic.WorkEnvelope` refusal codes have no S42 class | fixed on PR head |

The six unmapped codes (`AshA2A.SemanticRefusalTest`, "every refusal code found on disk is
explicitly mapped"): `refused_capability_contradiction`, `refused_graph_identity_mismatch`,
`refused_invalid_semantic_field`, `refused_missing_semantic_field`,
`refused_semantic_work_descriptor`, `refused_unbound_checkpoint`. They come from
`lib/ash_a2a/semantic/work_envelope.ex` (present on the PR head, absent on main), which is why
that test passes on main and fails on the PR.

## What changed on this branch (`errc/ash-a2a-format`)

- `test/test_helper.exs`: accumulates excluded tags. `:graphlaw` behavior is unchanged. New
  `:graphlaw_engine` is excluded when any of the seven resolved wasm paths or `node` is
  missing; new `:sibling_repos` is excluded when any of the 11 topology repos has no `.git`.
  Each exclusion prints its reason on stderr. Nothing is stubbed and nothing passes silently.
- 22 test files: `@tag`/`@moduletag` on exactly the tests that failed on the runner
  (`AdversarialInputTest` and `SemanticCrossPeerTest` are module-wide; the rest are per test).

## Evidence

- Base `2730c9b`, this tree, real environment, before the change: `mix compile
  --warnings-as-errors` exit 0, `mix format --check-formatted` exit 0, full `mix test`: 58
  doctests, 29 properties, 2122 tests, 0 failures, 2 skipped (18 excluded).
- Hosted-CI simulation (wasm paths pointed at a missing file through the app config and all
  five env vars, run over the 23 failing files):
  - forced-include (`--include graphlaw_engine --include sibling_repos`): 316 tests,
    103 failures; the failing set equals the CI set minus the 4 not reproducible locally
    (3 sibling-repo tests and the real defect), with 0 failures CI did not have.
  - as committed: 4 doctests, 213 tests, 0 failures, 3 skipped (122 excluded).
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
   in unrelated version-string hunks.
2. The refusal-class commit is `488ae22` on `errc/ash-a2a-pr27-refusal-classes` (cut from
   `8d61f46e`); it is only meaningful on the PR branch. With it,
   `test/ash_a2a/semantic_refusal_test.exs` (21 tests, including "every refusal code found on
   disk is explicitly mapped") and `test/ash_a2a_semantic_work_envelope_test.exs` pass, and
   `mix compile --warnings-as-errors` and `mix format --check-formatted` exit 0.
3. Both are candidates; neither was pushed. Merge order on the PR branch: `488ae22` first
   (real defect), then `8815f5b` (environment).

## Not configured

`mix credo` is not part of this repository (`credo` is not in `mix.exs` deps and there is no
`.credo.exs`; CI runs format, compile with warnings as errors, then `mix test`).

## See Also

- `docs/streams/ash-a2a-external-do.md` for the external-do override findings.
- `test/test_helper.exs` for the exclusion contract.
- `.github/workflows/ci.yml` for the hosted-CI step order.
