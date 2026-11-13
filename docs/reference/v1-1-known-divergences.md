# A2A v1.1 Known Divergences

Standing: PARTIAL

Register of known divergences between this repo's A2A v1.1 claim
([conformance statement](a2a-v1-1-conformance.md)) and an independently
verifiable v1.1 target. Dated 2026-11-13. Each row has a close condition.

## Upstream findings (WebFetch, 2026-11-13)

- `a2aproject/A2A` tags: `v1.1.0-rc` (2026-10-29), `v1.0.1` (2026-05-28),
  `v1.0.0` (2026-03-12). Releases page: latest is v1.0.1; no v1.1 release.
- `main` `specification/a2a.proto` (package `lf.a2a.v1`): v1.0 surface, 11 RPCs, no
  `SendLiveMessage`. It differs from the vendored corpus by every v1.1 item:
  `SendLiveMessage`, `StreamRequest`, `StreamError`, `TimelineEntry`,
  `TaskMessageUpdateEvent`, `Task.timeline` (8), `Artifact.role` (9),
  `AgentCapabilities.user_artifacts` (5), `TaskPushNotificationConfig.protocol_version`
  (7), `SendMessageRequest.artifact_updates` (5), `StreamResponse.message_update` (5)
  and `error` (6).
- `v1.1.0-rc` proto summary matches the vendored corpus on those items and field
  numbers (`SendMessageConfiguration.if_generation_match` 5 and `timeline_length` 6,
  `GetTaskRequest.current_generation` 4, `SubscribeToTaskRequest.last_seen_generation`
  3, `StreamError` 1-5). No upstream difference from the vendored corpus was found at
  that granularity. The fetch is a model summary, so byte equality is UNVERIFIED;
  the corpus court's SHA-256 pin is the only byte-level check.
- The rc summary names no error code; `-32010` (`TaskGenerationMismatchError`) is not
  confirmed upstream (the corpus court accepts it from "corpus docs or spec text").

## Register

| KD | Surface | Divergence | Evidence | Close condition |
|----|---------|------------|----------|-----------------|
| KD-V11-01 | v1.1 target | Target is the `v1.1.0-rc` tag, not a release; wire may change before v1.1.0 | tags page, releases page (above) | Upstream publishes v1.1.0; re-vendor, re-run `ash_a2a_v1_1_proto_corpus_test.exs`, diff the SHA-256 |
| KD-V11-02 | TCK | No v1.1 TCK: `a2a-tck` `main` is aligned to 1.0.1, so no v1.1 row has a TCK verdict | `a2a-v1-1-conformance.md` External TCK | TCK ships v1.1 requirements; run and record per row |
| KD-V11-03 | Corpus | Vendored `priv/a2a_v1_1_spec_corpus/a2a.proto` is an rc snapshot; byte equality with upstream re-fetch not verified this session | SHA-256 `8d9c363f...b127` pinned; WebFetch summary only | Fetch the rc tag raw file and compare `sha256` |
| KD-V11-04 | Error registry | `-32010` not confirmed in upstream rc text | rc proto summary names no codes | Locate the code in upstream spec text, or register as ash_a2a extension |
| KD-V11-05 | JSON-RPC binding | No live method in the proto for JSON-RPC; none implemented | `a2a-v1-1-conformance.md` row 1 | Upstream adds one |
| KD-ENV-01 | FiboFinance court | `test/ash_a2a/chicago/fibo_finance_test.exs` needs `GRAPHLAW_ABI_WASM` (compiled wasm); skipped/refused without it | test moduledoc | Set `GRAPHLAW_ABI_WASM` to a built artifact and record a passing run |
| KD-ENV-02 | SA2A-XRUNTIME-002 | Cross-runtime portability needs the `graphlaw_host` binary | `test/ash_a2a/chicago/cross_runtime_portability_test.exs` | Build `graphlaw_host`, run, record exit |
| KD-TRIAGE-01 | `C2Compromise.CourtTest` | 3 failures, untriaged: not attributed to v1.1 or to any other cause | coordinator report, no log read here | Reproduce, classify (pre-existing vs session-introduced), fix or register |

## See Also

- [A2A v1.1 conformance](a2a-v1-1-conformance.md)
- [TCK suite](tck-suite.md)
- [Spec-version mapping](a2a-spec-version-mapping.md)
