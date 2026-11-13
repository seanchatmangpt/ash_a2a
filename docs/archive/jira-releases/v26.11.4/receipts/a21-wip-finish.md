# A2-1 WIP-Finish Receipt — ash_a2a

Standing: PARTIAL_ALIVE

## Inventory + classification

Dirty state found on entry (`git status --short`):

- `M CHANGELOG.md` — Unreleased section with 4 entries (SagaControl removal
  `fc0de4f5`, graphlaw v26.10.28 compat `5fcf1538`/`fc0de4f5`, refusal-mapping
  truth-syncs `d8c6829f`, dep locks `9abc3054`). All four cited SHAs verified
  present in history; `SagaControl` grep over `lib/` + `test/` = zero hits
  (removal claim true); `docs/reference/graphlaw-v26.10.28-compat.md` exists
  and is tracked/clean. mix.exs `version: "26.10.8"`, tag `v26.10.8` is an
  ancestor of HEAD (42 commits after), and the Unreleased entries are exactly
  that post-tag work. **Classification: coherent as written — no edit needed.**
  (Pre-existing convention: CHANGELOG has no 26.10.6/7/8 sections; tags are
  campaign markers, e.g. v26.10.8 = `3ad578dd` docs scaffold.)
- `?? docs/thesis/` (6 files: main.tex + aux/log/out/toc/pdf) — stray untracked
  LaTeX build tree, not referenced by any code or doc. Left in place.
- `research/erc/ERC-001-179*.json` (6 files) — stale as of 2026-11-11: now
  committed (`git ls-files` = 6), no longer untracked. **Not stray.** The
  `research/erc/` directory is the ERC evidence ledger consumed by
  `lib/ash_a2a/research/erc.ex` (`mix eds.ledger` per archived Litho docs);
  43 sibling tracked JSONs already live there (ERC-001/003/004). The 6 new
  files are ledger entries recording the HDDL facilitator → beam4pm OCEL
  ingest claim, artifact SHA `13622178` (verified ancestor of HEAD). Left in
  place, not referenced by any in-flight doc (ledger entries are consumed by
  tooling, not prose). No files deleted.

## Commands + exits

- `mix deps.get` — exit 0 (fetched missing wasmex, ash_ex4pm, etc.)
- `mix compile` — first attempt exit 1: missing deps (pre-existing;
  session-introduced fix = deps.get). Full compile re-run in progress at
  receipt-writing time (ggen_graph_nif NIF release build + ggen_igniter,
  concurrent package-cache lock contention with lanes on smalt/xaas/cgap).
- GATE (mix compile exit 0): re-run 2026-11-11 by lane L16 under
  `MIX_BUILD_ROOT=_build-lane16` on the live dirty tree (no SHA-pinned subject):
  first attempt exit 1 (syntax error in `lib/ash_a2a/protocol/agent_card.ex:74`,
  another lane's in-flight edit, since fixed); re-run `mix compile` exit 0
  ("Generated ash_a2a app", 0 error lines). Standing kept PARTIAL_ALIVE: exit 0
  is on a dirty tree, not the original receipt subject.

## Owned files (this lane)

- `docs/jira/v26.11.4/receipts/a21-wip-finish.md` (this receipt, new)
- No source files modified. CHANGELOG.md verified, left byte-identical to
  its on-entry dirty state.
