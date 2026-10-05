# Manufacturing Receipt — v26.10.3 v1-Protocol Fan-Out (Lane F6)

Receipt for the v26.10.3 v1-protocol fan-out over the one canonical checkout
`/Users/sac/ash_a2a`. Every number below carries the command that reproduces it;
per the falsifier clause, a number whose command does not reproduce is void.
Evidence labels: OBSERVED = command output in this lane; SESSION = session/coordinator
testimony (cited, not re-run); DOC = committed doc restatement (path:line given).

- Subject: ash_a2a `main` @ `fbea16b3c645675db01a4a6002719f34dc2715a8`, tree dirty.
- Replay: `git -C /Users/sac/ash_a2a rev-parse HEAD`
- Base of the fan-out: `5a84d88` (see `_RESOLUTIONS.md` header).

## Exact Subject

```bash
git rev-parse HEAD   # fbea16b3c645675db01a4a6002719f34dc2715a8
git status --porcelain | wc -l   # 286 dirty paths
git status --porcelain | awk '{print $1}' | sort | uniq -c
# 73 '??', 213 'M'
```

Branch `main`, HEAD `fbea16b`, no tag. 286 dirty paths: 213 modified, 73 untracked.

## O / O*

- O (observed): TCK verdicts from the external authority `a2aproject/a2a-tck` at
  `main` (lane Z19 run, 2026-10-05, JSONRPC binding only); the tree state itself
  (286 dirty paths); operator directives naming the lanes and the wave plan.
- O* (admitted): the operator directives (testimony O* by fiat); the TCK
  compatibility run admitted as external-authority evidence for the JSONRPC
  binding only; the repo's own Chicago courts admitted as self-conformance
  evidence. Not admitted: TCK certification (never claimed), any verdict on
  bindings the TCK did not exercise (grpc, http_json — see conformance doc).

## μ / Diff Summary Per Wave

Counts are from `git status --porcelain` at HEAD `fbea16b` (replay above).

- Removal + re-host: `:a2a` hex dep removed (`git diff --stat mix.exs mix.lock`
  — 60 insertions, 10 deletions across both); wire surface re-hosted in-repo as
  `lib/ash_a2a/protocol/` — 41 `.ex` files, 6,472 LOC, entirely untracked; docs
  sweep 16 modified files under `docs/`; CHANGELOG `[26.10.3]` section.
  Replay: `find lib/ash_a2a/protocol -name "*.ex" | wc -l` (41);
  `wc -l lib/ash_a2a/protocol/*.ex | tail -1` (6472 total).
- v1.0 courts: 26 new `test/ash_a2a_v1_*.exs` files, 239 test definitions.
  Replay: `ls test/ash_a2a_v1_*.exs | wc -l`;
  `cat test/ash_a2a_v1_*.exs | grep -cE "^\s*test \""` (both above).
- Zach surface: `test/ash_a2a_zach_courts_test.exs` (7 test defs: non-vacuity,
  ToA2AError totality over globbed `deps/ash` error modules, Executor courts) +
  untracked `lib/ash_a2a/{executor,schema,to_a2a_error}.ex`, `verifiers/`,
  `providers/`, `domain*` (14 untracked paths under `lib/`).
- TCK: `transport/plug.ex` fixes pinned by
  `test/ash_a2a/transport/transport_court_test.exs` (`-32009` version gate,
  resubscribe `-32001`, card §8.6.1 cache headers); TCK matrix recorded in
  `docs/reference/a2a-v1-conformance.md` (see Commands / Exits below).
- Marketplace integration: `ggen.toml` (self-host pack
  `canonical-ash-projection-generator`; 4 shadowing packs excluded with reasons);
  `priv/ggen/ash_a2a/` projection; `.ggen-v2/receipt.json` chain (Andon Green).

Totals by directory (modified): test 100, lib 78, docs 16, swarm 14, plus
README/CHANGELOG/mix.exs/mix.lock/k8s. Untracked: lib 14, test 40, docs 6,
swarm 5, priv 2, plus thesis/examples/.ggen* artifacts.

## Generated vs Hand-Written

- Generated: `lib/ash_a2a/transport/grpc/pb/lf/a2a/v1/a2a.pb.ex` (protoc,
  `use Protobuf`); `priv/proto/` (vendored a2a.proto);
  `priv/ggen/ash_a2a/` (ggen RDF projection: `ontology.ttl`, `queries/`,
  `templates/`, `dfcm/`); `.ggen-v2/receipt*.json` (ggen receipt chain).
- Curated (neither): `priv/a2a_v1_spec_corpus/` (ggen.toml: "curated, not
  generated"); `priv/sa2a/AllSA2A.ttl` canonical graph (committed `c0c9411`,
  `5a84d88`).
- Hand-written: everything under `lib/` and `test/` outside the generated list —
  including all 50 Chicago court modules (`lib/ash_a2a/chicago/courts/`).
  ggen.toml excludes any pack whose templates would render `lib/`/`test/` code
  (shadowing = drift channel); nothing in lib/ is pack-rendered.

## Commands / Exits (the ladder gates)

All commands run in this lane on the exact subject above, cwd `/Users/sac/ash_a2a`.

- Compile — `mix compile --warnings-as-errors` — exit 0
  (`Generated ash_a2a app`).
- Mock grep gate — `grep -rnE "unittest\.mock|mockall|jest\.mock|Mox\."
  lib/ test/` — 18 raw hits, all inside the mock-scan machinery, its courts,
  and its allowlisted fixtures (`chicago/collaborators/mock_scan.ex`,
  `courts/real_collaborators.ex`, the `mock_discipline_test` allowlist); the
  repo's own court `test/ash_a2a_mock_discipline_test.exs` (regex at `:52`)
  passed inside the 70-test batch below.
- v1 conformance batch — `mix test test/ash_a2a_v1_conformance_test.exs
  test/ash_a2a_v1_pagination_test.exs test/ash_a2a_v1_cancellation_test.exs
  test/ash_a2a_v1_artifact_streaming_test.exs test/ash_a2a_v1_rejected_state_test.exs
  test/ash_a2a_v1_auth_challenge_test.exs test/ash_a2a_mock_discipline_test.exs`
  — exit 0, 70 tests, 0 failures.
- Context continuity — `mix test test/ash_a2a_v1_context_continuity_test.exs
  --include serial` — exit 0, 5 tests, 0 failures.
- Transport court (TCK pins) — `mix test
  test/ash_a2a/transport/transport_court_test.exs` — exit 0, 11 doctests,
  23 tests, 0 failures (4 excluded).
- Zach courts — `mix test test/ash_a2a_zach_courts_test.exs` — exit 0,
  7 tests, 0 failures.
- Fast lane — `mix test` — **exit 1, RED** (see below).

Fast-lane RED (OBSERVED, reproducible):

```bash
mix test test/ash_a2a/capability_index_agent_card_shape_test.exs   # exit 1
# == Compilation error ... test/ash_a2a/capability_index_agent_card_shape_test.exs:85
# ** (ArgumentError) the following keys must also be given when building
# struct AshA2A.Protocol.AgentCard: [:name, :description, :url, :version, :skills]
```

The bare `%AshA2A.Protocol.AgentCard{}` literal in the "capabilities member"
test is missing the `@enforce_keys` fields (`lib/ash_a2a/protocol/agent_card.ex:90`).
The compile abort kills the entire `mix test` run before any summary. This is a
current-tree defect in a wave-edited file (file is `M` in git status); it must be
killed before the integration commit.

## Verification Ladder (court families + counts)

- Chicago court modules: 50 files under `lib/ash_a2a/chicago/courts/`
  (`ls lib/ash_a2a/chicago/courts/ | wc -l`).
- Admitted court families (17) with per-family falsifier counts, from the pinned
  standing receipt `swarm/rel/overlays/standing/sa2a-conformance-501a4fdb.../
  chicago/standing_receipt.json` (`501a4fdb...` =
  `501a4fdbc427dc6ae50c64368126f2156d3b99c9`, `court.courts`): CHI-ADM, CHI-ID,
  CHI-REAL, SA2A-BENCH, SA2A-CANON, SA2A-ENV, SA2A-FED, SA2A-NEG, SA2A-NS,
  SA2A-OCEL, SA2A-OCEL-OBSERVER, SA2A-SHACL, SA2A-SHEX, SA2A-SPARQL, SA2A-TOPO,
  SA2A-TRANSPORT, SA2A-XRUNTIME — 187 falsifiers total, 134 killed, 0 survived,
  0 unknown; 3/3 gates passed; 48 positive controls passed; OCEL evidence
  3,202 events / 750 objects / 2,442,289 bytes, 0 dropped, 0 gaps.
  Replay:

  ```bash
  cd swarm/rel/overlays/standing/sa2a-conformance-501a4fdb\
c427dc6ae50c64368126f2156d3b99c9/chicago
  python3 -c "import json; d=json.load(open('standing_receipt.json')); \
print(d['results'], [c['id'] for c in d['court']['courts']])"
  ```
- Caveat (OBSERVED in the receipt itself): its `source_revision` is
  `501a4fdbc427dc6ae50c64368126f2156d3b99c9` with `dep:a2a 0.2.0` — a pre-removal
  pinned subject, stale relative to HEAD `fbea16b`. The 187/134/0 figures qualify
  that subject, not this one.
- TCK compatibility (DOC + SESSION, lane Z19, 2026-10-05): per
  `docs/reference/a2a-v1-conformance.md` — agent_card 10/10 pass; jsonrpc 68 pass
  / 5 fail / 15 skip of 88; grpc 0/72 (all skipped); http_json 3/83 (80 skipped);
  overall 69.2% (MUST 70.4%, SHOULD 42.9%, MAY 100%). Raw reports at
  `/tmp/z19/tck_reports_ash_a2a_final` are session-ephemeral (not committed).
- v1 conformance statement (DOC): 29 rows — 27 CONFORMANT, 2 PARTIAL (rows 21
  in-flight cancel, 22 `historyLength` on `tasks/list`).
  Replay: `grep -cE "^\| [0-9]+ \|" docs/reference/a2a-v1-conformance.md` (29);
  same grep piped to `grep -c CONFORMANT` (27) / `grep -c "| PARTIAL"` (2).
- v1 courts: 26 files / 239 test defs.
  Replay: `ls test/ash_a2a_v1_*.exs | wc -l` (26);
  `cat test/ash_a2a_v1_*.exs | grep -cE "^\s*test \""` (239).
- Transport court: 23 tests + 11 doctests (run above, exit 0).
- Zach courts: 7 tests (run above, exit 0).
  Replay: `grep -cE "^\s*test \"" test/ash_a2a_zach_courts_test.exs` (7).

## Standing (ALIVE per surface)

- Protocol codec + re-hosted wire surface: ALIVE (compile exit 0; v1 batch exit 0).
- v1.0 conformance courts: ALIVE (70 tests, 0 failures; 5 serial tests exit 0).
- TCK-pinned transport courts: ALIVE (23 tests + 11 doctests, exit 0).
- Zach surface (Executor/ToA2AError/VerifySkills): ALIVE (7 tests, exit 0).
- gRPC binding: code ALIVE by court count only (2 suites exist, cited below);
  TCK-over-gRPC never executed. PARTIAL_ALIVE, wire-verified but TCK-unknown.
- TCK JSONRPC compatibility: PARTIAL_ALIVE (69.2% point-in-time, not certification).
- Whole-suite fast lane: BLOCKED — one test-file compile break
  (`capability_index_agent_card_shape_test.exs:85`), exit 1, OBSERVED.

## Falsifiers Remaining Open

1. Fast-lane compile break (above) — NEW this session; blocking integration.
2. TCK `grpc` (0/72) and `http_json` (3/83, 80 skipped) suites unexecuted; the
   card advertises JSONRPC only at run time (conformance doc, "What is not claimed").
3. Standing receipt pinned to pre-removal subject `501a4fdb` (`dep:a2a 0.2.0`) —
   re-mint on the post-removal subject to keep the swarm release receipt binding.
4. `preferredTransport` codec gap: card round-trip drops the member
   (`lib/ash_a2a/protocol/agent_card.ex:18-23` moduledoc inventory).
5. Dead `stringify/1` clause, `transport/plug.ex:144-145`, unreachable behind `:140`
   (_RESOLUTIONS §2.3, integration residue).
6. Conformance rows 21/22 PARTIAL (conformance doc `:51-53`).
7. The 5 remaining TCK jsonrpc failures are pinned as echo-SUT harness contract
   (DM-ART-001, DM-MSG-001), not spec violations (conformance doc).
8. Durable task-list design: the v1 default `AshA2A.Protocol.TaskStore.ETS`
   reference store is in-memory; durability is opt-in behind the
   `AshA2A.TaskStore.Ekv` seam
   (`test/ash_a2a_v1_taskstore_durability_test.exs:4-15`). Durable-by-default list
   semantics remain an open falsifier (SESSION).
9. Mid-flight stream resume — issue #8 (SESSION-sourced; no tree artifact).
10. Card-verify / HTTP+JSON double assignment of `protocol/client.ex` resolved
    sequentially; single-owner re-assignment pending in the next `_LANES.md`
    (_RESOLUTIONS §1.1, PARTIAL).
11. Lane build roots left in the tree: `swarm/_build-laneF3-s`, `swarm/_build-laneK`,
    `swarm/_build-laneV5`, `swarm/_build-laneZ31-s` (4 of 5 untracked `swarm/`
    paths are leases, not assets) — coordinator deletes at integration per the
    cleanup law.
12. Five swarm modified files are release-tree artifacts (`swarm/_build` inside
    `git status` modified set) — same cleanup at integration.

## BLOCKED / UNSUPPORTED

- gRPC server dep boundary: `{:protobuf, "~> 0.17"}, {:grpc_server, "~> 1.0"},
  {:grpc, "~> 1.0"}` are required unconditionally (`mix.exs:469-471`); the TCK
  gRPC suite was not run, and the binding is a dependency-fenced surface —
  UNSUPPORTED(TCK-over-gRPC) until a TCK run over `AshA2A.Transport.GRPC.Server`.
- Official TCK certification: not claimed, by the conformance doc's own
  "What is not claimed" section — CONFORMANT in the repo always means "the pinned
  court passes", never "TCK-certified".
- Cited lane receipts (SESSION-sourced, not re-run in F6): Z13, Z33, M14, M17,
  M19. These are lane gate citations from the fan-out; no tree artifact carries
  their per-gate output, so they are admitted as testimony, not evidence.

## Transport Failures

- Disk pressure (OBSERVED): `:alarm_handler: {:set, {{:disk_almost_full,
  ~c"/System/Volumes/Data"}, []}}` fired during every test run in this lane; a
  second alarm named the CoreSimulator volumes. No test failed from it.
- Sibling repos: `[sibling_repos] EXCLUDING :sibling_repos tests -- 11 of 11
  sibling repos absent` — cross-repo courts excluded on this checkout.
- Rate limits: none observed in this lane (no `:external_api`-tagged live LLM
  test ran; the fast lane excludes them by default). Live-LLM rate-limit failures
  from other lanes are cited SESSION-sourced only.

## See Also

- `docs/jira/v26.10.3-v1-protocol/_RESOLUTIONS.md` (integration ledger)
- `docs/reference/a2a-v1-conformance.md` (29-row statement + TCK matrix)
- `CHANGELOG.md` `[26.10.3]` (wire retarget summary)
- `docs/jira/v26.9.28-kernel/_LANES.md` (lane-ledger convention)
- `~/.claude/rules/same-checkout-fanout.md`, `~/.claude/rules/operating-doctrine.md`
