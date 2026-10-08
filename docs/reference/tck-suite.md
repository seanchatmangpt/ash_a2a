# TCK Suite

How to run, inspect, and act on the A2A v1.0 conformance surface of this
repository: the pinned in-repo v1 conformance courts (executed by
`mix ash_a2a.v1_conformance_report`) and the external
`a2aproject/a2a-tck` compatibility suite. The normative per-requirement
statement lives in [A2A v1.0 conformance statement](a2a-v1-conformance.md);
this page is the operator instrument over it.

## The two surfaces

| Surface | What it judges | Where |
| --- | --- | --- |
| In-repo v1 conformance courts | that the pinned court for each spec requirement passes, executed as real OS subprocesses | `test/ash_a2a_v1_*.exs`, run by `lib/mix/tasks/ash_a2a.v1_conformance_report.ex` |
| Official A2A TCK (`a2aproject/a2a-tck`) | external, point-in-time wire compatibility across all three bindings | external repo, run against the in-tree SUT (`tck_sut.exs`) |

A full-PASS in-repo report is NOT TCK certification, and a TCK
compatibility percentage is a point-in-time verdict, not a standing
certification. Both framings are pinned in
[What is not claimed](a2a-v1-conformance.md#what-is-not-claimed).

## Running the in-repo conformance report

```bash
mix ash_a2a.v1_conformance_report
mix ash_a2a.v1_conformance_report --out receipts/v1-conformance.json
mix ash_a2a.v1_conformance_report --only v1_pagination
```

Mechanics (`lib/mix/tasks/ash_a2a.v1_conformance_report.ex`):

1. Takes the maintained court list `@v1_courts` in that module.
2. Verifies each entry against the real filesystem at runtime; a court
   file that no longer exists becomes an entry with `verdict: "FAIL"`
   and `exit_code: null` (a court you cannot execute is not a court
   that passed).
3. Runs each existing court as a real OS subprocess
   (`mix test <file> --include serial`), capturing exit code and the
   ExUnit summary line.
4. Emits one JSON document: `%{generated_at, elixir_version, courts,
   totals}` with `courts` = `%{file, exit_code, summary_line, verdict}`
   and `totals` = `%{pass, fail, total}`.

The task is a REPORT, not a gate: it always exits 0. The gate is the
JSON itself — `totals.fail == 0`.

Runtime expectation: minutes to tens of minutes (the serial tail drives
real Bandit loopback listeners and shared transports). Use `--only` to
iterate on a subset.

## Court inventory (26 courts)

The maintained list `@v1_courts` contains **26 court files**, all under
`test/`:

| # | Court file |
| --- | --- |
| 1 | `test/ash_a2a_v1_architecture_test.exs` |
| 2 | `test/ash_a2a_v1_artifact_streaming_test.exs` |
| 3 | `test/ash_a2a_v1_auth_challenge_test.exs` |
| 4 | `test/ash_a2a_v1_card_signing_test.exs` (DY3: CARD-SIGN-001..004 against the real CardSigning machinery) |
| 5 | `test/ash_a2a_v1_binding_mismatch_test.exs` |
| 6 | `test/ash_a2a_v1_cancellation_test.exs` |
| 7 | `test/ash_a2a_v1_conformance_test.exs` |
| 8 | `test/ash_a2a_v1_context_continuity_test.exs` |
| 9 | `test/ash_a2a_v1_error_registry_test.exs` |
| 10 | `test/ash_a2a_v1_extended_httpjson_test.exs` |
| 11 | `test/ash_a2a_v1_io_modes_test.exs` |
| 12 | `test/ash_a2a_v1_list_decode_test.exs` |
| 13 | `test/ash_a2a_v1_multinode_continuity_test.exs` |
| 14 | `test/ash_a2a_v1_oban_delivery_test.exs` |
| 15 | `test/ash_a2a_v1_owner_scope_test.exs` |
| 16 | `test/ash_a2a_v1_pagination_test.exs` |
| 17 | `test/ash_a2a_v1_proto_fidelity_test.exs` (Z16: codec vs the vendored official v1.0 IDL `priv/a2a_v1_spec_corpus/a2a.proto`) |
| 18 | `test/ash_a2a_v1_push_httpjson_test.exs` |
| 19 | `test/ash_a2a_v1_rejected_state_test.exs` |
| 20 | `test/ash_a2a_v1_security_requirements_test.exs` (Z24) |
| 21 | `test/ash_a2a_v1_spec_corpus_test.exs` |
| 22 | `test/ash_a2a_v1_sse_replay_test.exs` |
| 23 | `test/ash_a2a_v1_state_properties_test.exs` |
| 24 | `test/ash_a2a_v1_taskstore_durability_test.exs` |
| 25 | `test/ash_a2a_v1_telemetry_test.exs` |
| 26 | `test/ash_a2a_v1_wire_properties_test.exs` |

Deliberately NOT in the list (see the module's comment block):
`test/ash_a2a_v1_conformance_report_test.exs` (the runner's own
self-test; listing it would recurse) and
`test/ash_a2a_zach_courts_test.exs` (adversarial extension courts over
the DSL/executor surface — not v1.0 protocol conformance).

## Witnessed verdicts

### In-repo report — 26/26 PASS (as of 2026-10-08)

`mix ash_a2a.v1_conformance_report` at post-bump HEAD `a9cc903b`
(v26.10.8): **26/26 PASS, 0 FAIL** (`totals: {total: 26, pass: 26, fail:
0}`, task exit 0), executed 2026-10-08T10:01:27Z. Witnessed in the
campaign receipt `docs/jira/v26.10.8/RECEIPT.md` ("Gate verdicts"),
branch `feat/tck-vuln-hardening`. **As-of-date**: this verdict is bound
to subject `a9cc903b`; re-run the report to renew it at a later head.

Earlier witnessed runs (kept for trajectory, see the conformance
statement's Verification section): 25 PASS / 0 FAIL over 25 courts at
subject `059ff0e3` (2026-10-05), and a G6 integration re-run at tree
`2379635c` that selected 26 courts and reported 23 PASS / 3 FAIL — the
3 were the in-flight `tasks/resubscribe`/SSE-streaming semantics
changes, reproducible standalone with `--include serial` and green
after the streaming lane landed.

### Official TCK compatibility — 79.0% (point-in-time)

The official `a2aproject/a2a-tck` suite ran against the real `ash_a2a`
SUT on all three wire bindings; the latest witnessed verdict (2026-10-06,
branch `feat/tck-vuln-hardening`, HEAD `cadb6534`) is **79.0% overall,
235 passed / 30 skipped / 0 FAIL, MUST 87/87, SHOULD 7/7, MAY 4/4** —
zero failing requirements. The earlier 2026-10-05 run at G6 tree
`2379635c` was **73.6%** (92 PASS / 7 FAIL / 4 SKIPPED / 26 NOT TESTED),
with all 7 failing requirement classes enumerated in the conformance
statement. Full matrices, per-requirement breakdowns, and the DY4
auth/TLS extension run:
[a2a-v1-conformance.md — A2A TCK compatibility run](a2a-v1-conformance.md#a2a-tck-compatibility-run).

## What MUST-class failures convert to

Precedent: TCK MUST-class infrastructure failures become transport
fixes in `lib/`, not doc notes. The 2026-10-05 lane-Z19 run surfaced
three MUST failures — a missing `A2A-Version` header gate (spec-mandated
`-32009`), `tasks/resubscribe` answering `-32004` instead of `-32001`
on unknown tasks (spec §3.16/STREAM-SUB-004), and a missing card
`Cache-Control`/`ETag` (spec §8.6.1). All three were fixed in
`lib/ash_a2a/transport/plug.ex` and re-verified green in the subsequent
runs (see the conformance statement's progress notes and the C27
"TCK-driven fix loop" composition history: 3 real bugs found and fixed
in one loop). The G6 run's remaining 7 FAIL classes (push lifecycle,
gRPC extended card, gRPC stream-close isolation) were likewise
converted: the 2026-10-06 run reports 0 FAIL.

## Raw reports

Raw TCK reports (JUnit, HTML, `compatibility.json`) live in
`/tmp/a2a-tck/reports` — session-ephemeral, not committed; re-run the
suite to regenerate. TCK in CI: the `tck` job in
`.github/workflows/ci.yml` runs the official suite against the in-tree
SUT.

## See Also

- [A2A v1.0 conformance statement](a2a-v1-conformance.md)
- [A2A endpoint contract](a2a-endpoint-contract.md)
- [A2A spec version mapping](a2a-spec-version-mapping.md)
- [Conformance profiles](conformance-profiles.md)
