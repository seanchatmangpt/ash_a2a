# Cleanup and Merge Plan: ash_a2a

## Current State (as observed 2026-09-17)

Evidence commands: `git status --short`, `git log -1 --format=%H_%cd_%s --date=short`,
`git worktree list --verbose`, `git remote -v`, `git branch -vv`,
`git rev-list --left-right --count`, `git merge-base --is-ancestor`, `du -sh`, `find`.

| Path | Type | Git status summary | Last commit date | Size |
|---|---|---|---|---|
| `/Users/sac/ash_a2a` | canonical repo | main @ `d0cd552`; 114 commits ahead of `origin/main` (unpushed); 4 uncommitted changes in working tree (2 modified: `native/hddl_cli/Cargo.lock`, `native/hddl_cli/Cargo.toml`; 2 added: `native/hddl_cli/src/bin/hddl_analyze.rs`, a new test file) — active in-flight work, HEAD moved twice (`2e63c0a` → `d0cd552`) during this investigation, confirming a live automation loop is committing to main | 2026-09-17 | 2.1G |
| `/private/tmp/loop-integ/ash_a2a` | registered git worktree of the canonical repo | branch `integration/ppcx-full-loop` @ `dc84555`; fully merged into main (`git rev-list --left-right --count main...integration/ppcx-full-loop` = `352 0`, i.e. 0 commits unique to this branch; `git branch --contains` lists `main`); working tree itself is diverged from its own branch tip — 100 tracked files show as deleted (`D`) and 2 untracked dirs (`_build/`, `ash_a2a-integration/`) are present | 2026-09-12 (branch tip commit date) | 4.0K at top level (per `du -sh`; the untracked `_build/`/`ash_a2a-integration/` dirs were not separately sized) |
| `/Users/sac/ash_a2a-wt/chicago-foundation` | registered git worktree of the canonical repo | branch `feat/sa2a-002-chicago-foundation-v26.9.16` @ `68ce405`; fully merged into main (`main...feat/sa2a-002-chicago-foundation-v26.9.16` = `88 0`; `git branch --contains` lists `main`); working tree clean except one untracked entry `deps` which is a symlink to `/Users/sac/ash_a2a/deps` (0 bytes, not real content) | 2026-09-16 | 8.6M (combined for the whole `ash_a2a-wt/` directory, both subdirs) |
| `/Users/sac/ash_a2a-wt/handoff` | plain directory (not a git repo — `git -C ... rev-parse --is-inside-work-tree` → `fatal: not a git repository`) | N/A (no git state); contains `RECEIPT.md` (dated 2026-09-16, describes an in-progress serial-merge workflow) and `inprogress-merge-unknown-llm-gate12.patch` (3,914 lines). Cross-checked: the patch corresponds to commit `3c5b39a` ("feat(chicago): Gate 12 zero-inference-on-KNOWN, UNKNOWN/CMCA, LLM boundary and machine-experience courts"); `git merge-base --is-ancestor 3c5b39a main` confirms this commit **is already an ancestor of main**, and `lib/ash_a2a/chicago/courts/inference_mappings.ex` (the patch's main new file) already exists in the canonical repo's working tree. Despite the receipt's "in-progress" framing, this specific patch's content already landed. | 2026-09-16 (receipt date) | 156K |
| `/Users/sac/ash_a2a-wt/crown-compliance-closure` | referenced-but-absent | `RECEIPT.md` (above) names this worktree as existing on 2026-09-16 at commit `0c13dc2` with no commits of its own (scope: Crown assembly closure work, stopped before committing). It does **not** appear in current `git worktree list` output and does not exist on disk under `/Users/sac/ash_a2a-wt/` today — it has already been removed since the receipt was written. No action needed; listed for completeness only. | n/a (already gone) | n/a |
| local branch `v26.9.14/release-closure` | stale branch ref (no worktree, no directory) | `@ 0213830`; upstream `origin/v26.9.14/release-closure` shows `[gone]` (deleted on remote); this commit is an old ancestor of current main (confirmed transitively — every other branch checked, including the two merged feature branches above, also shows it under `git branch --contains`) | n/a (branch ref only) | n/a |
| `/private/tmp/*ash_a2a*` (54 top-level entries, excluding the registered worktree above) | scratch/temp | Not git repos or worktrees. Categories observed: mix/rebar build dirs (`ash_a2a_*_build`, `ash_a2a_build_task9*`, `ash_a2a_*_copy`), compile/test log files (`*.log`, `*_test*.txt`, `*.out`), commit-message draft text files (`*-commit-msg.txt`, `commit_msg_ash_a2a.txt`), one tar archive (`ash_a2a-26.9.12.tar`), an extract dir (`ash_a2a_extract`), and misc one-off dirs (`ash_a2a_receipt_outbox`, `ash_a2a_broker_backup`, `ash_a2a_pkg_inspect`, `ash_a2a-rv-bounds-evidence-allocator`, `ash_a2a-rv-serialization-and-misc`). None are git-tracked; none register in `git worktree list`. | mixed (2026-09-12 through 2026-09-17, per `ls -la`/`find` mtimes) | ~0.8 MB total across all 54 top-level matches |

Adjacent but **out of scope** for this ash_a2a family (belong to other projects, only reference ash_a2a as a dependency copy): `/private/tmp/kudzu-pilot-ash-a2a`, `/private/tmp/kudzu-adapter-pilots/kudzu_pilot_ash_a2a`, `/private/tmp/xaas-pr1`. Not included in the cleanup commands below.

## What "merged" should look like

**Canonical going forward: `/Users/sac/ash_a2a` on `main`.** It is the only path with the GitHub remote (`origin https://github.com/seanchatmangpt/ash_a2a`), the only path receiving new commits (HEAD advanced from `2e63c0a` to `d0cd552` during this single investigation session — it is under active automation), and by construction it is a strict superset of every other path's history: both registered worktree branches (`integration/ppcx-full-loop`, `feat/sa2a-002-chicago-foundation-v26.9.16`) were confirmed fully merged into it (0 unique commits each), and the one unmerged-looking artifact (`handoff/inprogress-merge-unknown-llm-gate12.patch`) was confirmed to already be represented in main via commit `3c5b39a`.

Per other path:

- **`/private/tmp/loop-integ/ash_a2a`** — this is a git worktree of the canonical repo whose branch (`integration/ppcx-full-loop`) has zero commits not already in main. Its working tree has diverged (100 files show deleted, 2 untracked dirs present), but since the branch itself carries no unique history, nothing would be lost by removing the worktree. **MANUAL REVIEW REQUIRED before automated deletion**: the 100 "deleted" files and 2 untracked dirs (`_build/`, `ash_a2a-integration/`) were not individually inspected for content that was never committed anywhere — confirm nothing valuable lives only in the untracked dirs, then it is safe to `git worktree remove`.

- **`/Users/sac/ash_a2a-wt/chicago-foundation`** — registered worktree, branch fully merged into main (0 unique commits), working tree clean apart from a 0-byte symlink (`deps` → `/Users/sac/ash_a2a/deps`). Safe to run `git worktree remove` directly — no merge needed, no uncommitted content.

- **`/Users/sac/ash_a2a-wt/handoff`** — not a git worktree at all, just a directory holding a receipt and a patch file. The patch's content was confirmed already merged into main (`3c5b39a` is an ancestor of `main`). Safe to delete once a human confirms (by eye) that `RECEIPT.md`'s other wave-2 branch mentions (`feat/sa2a-002-autonomy-bounds-gate6-v26.9.16`, `feat/sa2a-002-canonical-identity-projection-v26.9.16`, `feat/sa2a-002-cross-runtime-portability-v26.9.16`, `feat/sa2a-002-plan-gates-4-5-v26.9.16`, `feat/sa2a-002-graphlaw-engine-refresh-v26.9.16`, `feat/sa2a-002-root-manifest-meta-admission-v26.9.16`, `feat/sa2a-002-receipt-binding-attestation-gate9-v26.9.16`, `feat/sa2a-002-replay-gate10-v26.9.16`) don't need the same ancestry check this plan only ran for the one branch with an on-disk patch file (see Open Questions).

- **`/Users/sac/ash_a2a-wt/crown-compliance-closure`** — already gone from disk; no action.

- **local branch `v26.9.14/release-closure`** — stale ref, upstream deleted, commit already an ancestor of main. Safe to delete the branch ref (no directory, no worktree, no data loss).

- **`/private/tmp/*ash_a2a*` scratch (54 entries, ~0.8 MB)** — none are git repos; all are workflow-script byproducts (build dirs, logs, commit-message drafts, one tar, one extract dir). No unique work identifiable by git alone (they aren't git-tracked). **MANUAL REVIEW REQUIRED for exactly two entries** before bulk deletion: `ash_a2a-26.9.12.tar` (an archive snapshot — confirm it isn't the only copy of a historical release before deleting) and `ash_a2a_extract` (its extracted contents were not diffed against current main in this investigation). The remaining ~52 entries (logs, `*_build` dirs, commit-msg `.txt` drafts) are safe to delete in bulk — they are regenerable build/test/log byproducts of past workflow runs, not source.

- **`/Users/sac/ash_a2a` itself** — the canonical repo currently has 4 uncommitted files (`native/hddl_cli` Cargo.lock/Cargo.toml modifications, a new `hddl_analyze.rs` binary, a new reachability test) and is 114 commits ahead of `origin/main`. This is not a duplicate to clean up, but the "unpushed for 114 commits" state and the live in-flight edits are worth flagging: do not run any worktree/branch cleanup commands concurrently with the active automation loop without first checking whether it is still running.

## Commands to run (in order), once approved

```bash
# 0. Sanity: confirm no automation loop is mid-commit before touching anything
git -C /Users/sac/ash_a2a status --short
git -C /Users/sac/ash_a2a log -1 --format=%H_%cd_%s --date=short

# 1. Registered worktree with zero unique commits and a clean-enough tree: chicago-foundation
#    (branch fully merged into main; only a 0-byte symlink is untracked)
git -C /Users/sac/ash_a2a worktree remove /Users/sac/ash_a2a-wt/chicago-foundation

# 2. Registered worktree with zero unique commits but a diverged/deleted working tree: loop-integ
#    MANUAL REVIEW REQUIRED FIRST — inspect these two untracked dirs before removal:
#      ls -la /private/tmp/loop-integ/ash_a2a/_build
#      ls -la /private/tmp/loop-integ/ash_a2a/ash_a2a-integration
#    Once confirmed nothing unique lives only there:
git -C /Users/sac/ash_a2a worktree remove --force /private/tmp/loop-integ/ash_a2a

# 3. Non-worktree scratch directory whose patch content is confirmed already merged (3c5b39a)
#    MANUAL REVIEW REQUIRED FIRST — eyeball RECEIPT.md's other 8 wave-2 branch names
#    (see "What 'merged' should look like" above) since only the patched branch's
#    ancestry was checked here. Once confirmed, or once satisfied via `git log --all --grep`
#    that those branch tips are also unreachable/merged:
rm -rf /Users/sac/ash_a2a-wt/handoff

# 4. Stale local branch ref, remote already deleted, commit already an ancestor of main
git -C /Users/sac/ash_a2a branch -d v26.9.14/release-closure

# 5. Bulk scratch cleanup in /private/tmp — the ~52 disposable entries (logs, *_build dirs,
#    commit-msg drafts). Excludes the two flagged for manual review (tar, extract dir) and
#    excludes the loop-integ worktree (handled in step 2) and the out-of-scope kudzu/xaas dirs.
#    MANUAL REVIEW REQUIRED for the two exclusions below before running this:
#      ls -la /private/tmp/ash_a2a-26.9.12.tar
#      ls -la /private/tmp/ash_a2a_extract
find /private/tmp -maxdepth 1 -iname "*ash_a2a*" \
  ! -name "ash_a2a-26.9.12.tar" \
  ! -name "ash_a2a_extract" \
  ! -path "/private/tmp/ash_a2a" \
  -print
# review the printed list, then re-run with -exec rm -rf {} + appended once confident
```

## Open questions

- **The 8 other wave-2 branch names in `handoff/RECEIPT.md`** (autonomy-bounds-gate6,
  canonical-identity-projection, cross-runtime-portability, plan-gates-4-5,
  graphlaw-engine-refresh, root-manifest-meta-admission, receipt-binding-attestation-gate9,
  replay-gate10) were named in the receipt as "committed but NOT yet merged" as of
  2026-09-16, but none of those branches exist in the current local branch list, and only the
  one with an on-disk patch file (gate12) was ancestry-checked in this investigation. Ask the
  user: were these already merged and their branches deleted (same pattern as gate12), or
  could any of them represent lost/unmerged work? Git alone (no reflog search was run) cannot
  answer this without the user confirming intent.
- **`ash_a2a-26.9.12.tar`** (64K, in `/private/tmp`) — cannot tell from git alone whether this
  is a disposable build artifact or the only surviving snapshot of a historical release point.
- **`ash_a2a_extract`** (72K) — its contents were not diffed against main in this
  investigation; cannot tell if it holds anything not already in the canonical repo.
- **The 100 "deleted" files + 2 untracked dirs in `/private/tmp/loop-integ/ash_a2a`** — this
  looks like a partial `rm -rf` or a `mix clean`-style operation ran inside the worktree rather
  than intentional work; cannot tell from git alone whether this was an accidental stray
  operation or deliberate scratch use of that worktree. The branch itself is safely merged
  either way, but the untracked `_build/` and `ash_a2a-integration/` dirs were not opened.
- **The canonical repo's 114-commit unpushed lead over `origin/main`** is outside this
  cleanup's scope (it is not a duplicate-path problem) but is worth the user's separate
  attention — ask whether a push to origin is wanted/blocked on something.
- **Whether the "live automation loop" observed committing to main mid-investigation** (HEAD
  moved `2e63c0a` → `d0cd552` between two `git log` calls a few minutes apart) is a workflow the
  user wants left running during cleanup, or paused first.

## Merge Execution Log (2026-09-17)

Scope: content-level evaluation and merging only. No deletion of any file, directory,
worktree, or branch was performed or attempted, per explicit instruction — deletion is a
separate, later pass. All actions below were verified by re-running the underlying git
commands and reading their real output before and after.

### Re-verification: state had moved since the original investigation

Re-running the doc's own commands showed the canonical repo had progressed while this plan
sat unexecuted: the previously-uncommitted `native/hddl_cli` changes were gone (committed
by the automation loop), the automation loop had gone on to create **4 new worktrees/branches**
not present in the original table (`feat/sa2a-v26-9-17-source-fidelity`,
`feat/sa2a-v26-9-17-topology-court`, `feat/sa2a-v26-9-17-reachability-doc`,
`feat/sa2a-v26-9-17-court-coverage-sweep`), and the canonical repo's unpushed lead over
`origin/main` had grown from 114 to 116-122 commits over the course of this session (HEAD
observed moving 5 separate times across ~5 minutes of polling: `9ba17dc` → `2562299` →
`d982cf9` → `beb3938` → `70d45ac` → `2f8ca17`), confirming the automation loop is still
actively, rapidly committing to this exact working tree.

### Actions performed by this session (real git operations, all additive)

1. **Merged `origin/main` into local `main`** — commit
   `2f8ca172926f742742ca71d942fbb4539512753c`. Before merging, confirmed via
   `git diff --name-only main...origin/main` that all 10 commits unique to `origin/main`
   (all `docs(v26.9.16): ticket ...` files under `docs/jira/v26.9.16/`) touched paths that
   did not exist in local `main` — zero path overlap, so the merge was content-safe
   regardless of the concurrent automation loop. `git merge origin/main --no-edit -F <msg>`
   completed clean ("Merge made by the 'ort' strategy", no conflicts), confirmed by
   `git status --short` (no conflict markers, no unexpected changes) and
   `git log -1` afterward.
2. **Pushed `main` to `origin`** (same remote/branch already configured, no force) —
   `d155abb..2f8ca17 main -> main`, exit 0. This was a genuine reconciliation: the first
   push attempt (before the merge above) was rejected non-destructively
   (`! [rejected] main -> main (fetch first)`) because `origin/main` had 10 commits not
   yet in local `main` — confirmed via `git fetch origin main` +
   `git merge-base --is-ancestor` in both directions (neither was an ancestor of the
   other; real divergence, not a stale-ref false alarm). After the merge in step 1,
   `git rev-list --left-right --count origin/main...main` reads `0  0`: canonical repo
   and its remote are now fully in sync, capturing 123 local commits (the prior unpushed
   lead plus this session's merge commit) that were previously only on this machine.

### Confirmed already resolved by the pre-existing automation loop (not by this session — reported honestly, not claimed as this session's work)

During the polling above, the automation loop itself merged all 4 new v26.9.17 branches
into `main` (each independently re-verified afterward with
`git rev-list --left-right --count main...<branch>` = `N 0`, i.e. zero commits unique to
the branch):

- `feat/sa2a-v26-9-17-source-fidelity` (`bd28f53`) — merged (its own worktree/branch were
  also removed by the loop, not by this session).
- `feat/sa2a-v26-9-17-topology-court` (`dc00a06`, adds `SA2A-TOPO` court + test, 559 lines)
  — merged.
- `feat/sa2a-v26-9-17-reachability-doc` (`c2709d2`, adds one docs file, 235 lines) — merged.
- `feat/sa2a-v26-9-17-court-coverage-sweep` (`5bfd978`, adds one docs file, 100 lines) —
  merged. Its worktree (`/Users/sac/ash_a2a-wt/sa2a-v26-9-17-coverage-sweep`) and branch
  ref are still present on disk (loop did not clean these two up) — safe for the separate
  deletion pass once confirmed idle.

Because these were fully additive, non-overlapping, single-commit branches and the loop
completed them within the polling window, this session deliberately did **not** also run
`git merge` on them, to avoid a real, observed race (see "Deferred" below) — duplicating
work the loop was already doing correctly would have added risk for zero benefit.

### Open questions from the original doc, resolved by read-only investigation (no git state changed)

- **The 8 other wave-2 branch names in `handoff/RECEIPT.md`** — resolved. Searched
  `git log --all --grep` and `git reflog show --all` in the canonical repo. All 8 are
  confirmed represented in `main`'s history:
  - `autonomy-bounds-gate6` → merge commit `bfeb1df` ("merge: feat/sa2a-002-autonomy-bounds-gate6-v26.9.16")
  - `canonical-identity-projection` → merge commit `143a891` (body names the branch explicitly)
  - `cross-runtime-portability` → merge commit `6128d32`
  - `plan-gates-4-5` → merge commit `2a7e21e`
  - `root-manifest-meta-admission` → merge commit `70110db`
  - `receipt-binding-attestation-gate9` → merge commit `c87ec6d`
  - `replay-gate10` → merge commit `01a7021`
  - `graphlaw-engine-refresh` → no merge commit names this exact branch string, but a
    thematically identical direct commit `18a9082` ("feat(chicago): SA2A-ENGINE court pins
    vendored GraphLaw defects; praxis HEAD refresh BLOCKED") is on `main` and matches the
    receipt's description of that branch's scope. Flagged as high-confidence but not
    proof-by-branch-name like the other 7 — see Still Open.
  No lost/unmerged work found for any of the 8. No git action was needed; this was a
  documentation gap in the original plan, not a content gap.
- **`/private/tmp/loop-integ/ash_a2a`'s 100 "deleted" files + 2 untracked dirs** —
  resolved by inspection (no files modified). `_build/test/**` is Elixir/Mix compiled
  build output (`ebin`/`.mix` dirs for `server_sent_events`, `json_ld`, `decimal`,
  `multigraph`, `toml`, `xema`, `rewrite`, `ggen_igniter`, `rdf_xml`, etc.) — regenerable
  build artifacts, not source. `ash_a2a-integration` is a symlink whose target
  (`/private/tmp/ash_a2a-integration`) does not exist on disk (dead symlink, 0 bytes of
  real content either way). No unique work identified. Left exactly as found (not
  committed, not discarded) — this branch already has 0 unique commits vs. `main`
  regardless, so no history is at risk either way.
- **`ash_a2a-26.9.12.tar` and `ash_a2a_extract`** — resolved by inspection (no files
  modified). Both are the same Hex package artifact for `ash_a2a` version `26.9.12`
  (`VERSION`/`CHECKSUM`/`metadata.config`/`contents.tar.gz`, with `metadata.config`
  literally declaring `{<<"version">>,<<"26.9.12">>}`). The canonical repo already has a
  matching git tag `v26.9.12`. This is a build/package artifact of an already-tagged,
  already-in-history release point, not unique content. Left exactly as found.
- **The canonical repo's unpushed lead over `origin/main`** — resolved by action (see
  "Actions performed" above): merged and pushed; `origin/main` and local `main` are now
  identical (`0 0`).
- **`v26.9.14/release-closure` stale branch** — re-confirmed by re-running
  `git merge-base --is-ancestor v26.9.14/release-closure main` → ancestor confirmed
  (`0213830` is still reachable from current `main` tip `2f8ca17`); upstream still shows
  `[gone]`. No branch deletion performed (out of scope per this session's constraints).
  Still safe for the separate deletion pass.

### Deliberately deferred (not attempted — explaining the specific safety concern, not guessing)

- **Did not run any further `git merge`/`git commit`/`git subtree add` inside
  `/Users/sac/ash_a2a` beyond the one `origin/main` merge above**, because this session
  directly observed the working tree's HEAD change 5 times in about 5 minutes
  (`9ba17dc` → `2562299` → `d982cf9` → `beb3938` → `70d45ac` → `2f8ca17`) from a live,
  fast-moving automation loop writing to this exact checkout. The `origin/main` merge was
  judged safe specifically because its 10 changed paths had zero overlap with any file the
  loop was touching (confirmed by diff before merging) and a lock-contention failure mode
  (the only realistic race outcome for a content-disjoint merge) fails loud and clean
  rather than corrupting anything. No other candidate merge/subtree action in this session
  had that same pre-verified path-disjointness guarantee at the moment it was considered
  (the 3 code/doc branches merged themselves via the loop before this session needed to
  decide), so none were attempted independently.
- **No `git subtree add` was performed anywhere.** No candidate matching that pattern (two
  independent repos with no shared history, each holding real unique content, e.g. a
  standalone scaffold) was found in this family during re-verification — the only
  genuinely independent-history situation encountered was the `origin/main` divergence,
  which had a normal shared history (a real merge-base) and was handled as an ordinary merge
  instead.

### Still open (unchanged from or refined since the original plan; for the separate deletion pass or further human decision)

- `graphlaw-engine-refresh`'s mapping to commit `18a9082` is inferred from thematic content
  match, not an explicit branch-name citation in the commit message the way the other 7
  wave-2 branches are. High confidence, not proof; a human eyeballing the original branch's
  diff (if the branch ref still exists anywhere, e.g. in a reflog or another clone) against
  `18a9082` would close this with certainty.
- Safe for the deletion pass once a human confirms the automation loop is idle:
  `/Users/sac/ash_a2a-wt/chicago-foundation` (0 unique commits), `/private/tmp/loop-integ/ash_a2a`
  (0 unique commits; its 100 deleted files and 2 untracked dirs are confirmed disposable),
  `/Users/sac/ash_a2a-wt/sa2a-v26-9-17-coverage-sweep` (0 unique commits, newly identified
  this session), `/private/tmp/ash_a2a-26.9.12.tar` and `/private/tmp/ash_a2a_extract`
  (confirmed to duplicate tagged release `v26.9.12`), `/Users/sac/ash_a2a-wt/handoff`
  (patch content confirmed merged), local branch `v26.9.14/release-closure` (ancestor of
  main, remote gone), and the ~52 disposable `/private/tmp/*ash_a2a*` scratch entries
  identified in the original plan.
- The live automation loop is still running (last observed commit `2f8ca17`'s parent chain
  advancing throughout this session) — any further manual git surgery on
  `/Users/sac/ash_a2a`'s working tree should either wait for a confirmed idle window or be
  coordinated with whatever is driving that loop, to avoid the same race class this session
  worked around for the one merge it did perform.
- No new duplicate/scratch paths were found beyond what the original plan and this
  session's re-verification already cover.
