# ash_a2a migration plan v26.11.16

Standing: UNVERIFIED

## Identity
- Path: /Users/sac/ash_a2a
- Remote: https://github.com/seanchatmangpt/ash_a2a (origin/main)
- Branch: main@a6a98d2a, last commit 2026-11-13, 1412 commits
- Size: 4506 MB (of which _build 804M, deps 491M)
- Languages/build: Elixir (mix.exs), Rust NIF dirs (native/, sa2a_crypto), ggen.toml
- Nested repos: none

## Observed state
- Dirty (4 modified): docs/reference/a2a-v1-conformance.md, lib/ash_a2a/chicago/mutation/catalog.ex,
  test/ash_a2a/security_profile/boot_test.exs, test/ash_a2a_zai_concurrency_ocel_test.exs
- Untracked (5): docs/jira/ (this catalogue), test/ash_a2a_pack_replay_court_test.exs,
  test/ash_a2a_security_mutation_witness_test.exs
- Ahead/behind origin/main: 0/0. Stash count: 0.
- Unpushed local branches: 30 (feat/*, fix/*, preserve/v26.9.22/stash-0..4, backup/pre-rewrite-*,
  law/*, harden/*, integration/ppcx-full-loop, v26926/*). None track origin.
- Build dirs: _build 804M, deps 491M, _build-coord (unmeasured). Tarballs ash_a2a-26.9.12.tar,
  ash_a2a-26.9.31.tar and erl_crash.dump at root. No submodules.

## What it is
Spark DSL extension exposing Ash resource/domain actions as A2A-protocol agent skills over
JSON-RPC/HTTP/gRPC, published on Hex as ash_a2a 26.11.13. Recent work is pm4exunit-driven
multi-agent conformance tests.

## Classification
ACTIVE (census agrees: committed 3 days ago, published package).

## Migration risk
HIGH. 4 modified + 2 new test files uncommitted; 30 local-only branches including 5 preserved
stash branches and a pre-rewrite backup that exist nowhere else. Local-only data: two release
tarballs, receipts/, tmp/, notes/ (verify whether tracked).

## Recommended action
COMMIT-PUSH
1. `cd /Users/sac/ash_a2a && git status` — review the 4 modified and 2 new test files.
2. `git add -A && git commit -F <msg>` (repo convention: no inline -m) then `git push origin main`.
3. Push every local branch: `git push origin --all` (30 branches). DECISION: prune the
   preserve/v26.9.22/stash-* and backup/pre-rewrite-* branches after push, or keep as history.
4. `rm -rf _build _build-coord deps erl_crash.dump` to shrink to ~3.2 GB before any rsync.
5. DECISION: keep or delete ash_a2a-26.9.12.tar / ash_a2a-26.9.31.tar (Hex already has releases).
6. `git bundle create ash_a2a.bundle --all` to the archive volume as belt-and-braces.
7. On new machine: clone fresh; do not rsync the working tree.

## First commands on the new machine
`git clone https://github.com/seanchatmangpt/ash_a2a && cd ash_a2a && mix deps.get && mix compile && mix test`

## See Also
- ../v26.11.15/
- /Users/sac/docs/jira/v26.11.16/README.md
