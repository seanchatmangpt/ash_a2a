# v1-1-live-and-generations

Standing: PARTIAL

How to use the A2A v1.1 live stream, task generations and optimistic concurrency
against an ash_a2a agent. Row-level courts: [A2A v1.1 conformance](../reference/a2a-v1-1-conformance.md).
Select v1.1 with the `A2A-Version: 1.1` header.

## Read generation and timeline

Every task carries `generation` (monotonic integer) and `timeline[]`. Truncate the
timeline with `timelineLength`.

```bash
curl -H 'A2A-Version: 1.1' "$BASE/tasks/$ID?timelineLength=5"
```

## Long poll for the next generation

Pass the generation you already hold. The server parks until the task advances, is
terminal, or `config :ash_a2a, :long_poll_timeout_ms` (default 30_000) elapses.

```bash
curl -H 'A2A-Version: 1.1' "$BASE/tasks/$ID?currentGeneration=3"
```

## Guard a send with ifGenerationMatch

Set `configuration.ifGenerationMatch` on `SendMessage`. A stale value is JSON-RPC
`-32010` (`TASK_GENERATION_MISMATCH`) or HTTP 409 with status `ABORTED`; re-read the
task and retry.

```json
{"message": {"taskId": "T1"}, "configuration": {"ifGenerationMatch": 3}}
```

## Live stream

`POST /message:live` (HTTP+JSON) and gRPC `SendLiveMessage` open an SSE downlink whose
first frame is a Task snapshot. The agent card must declare `capabilities.streaming`.
JSON-RPC has no live method. A `StreamRequest` naming a different task yields a
`StreamError` frame and the stream stays open.

## Resume a subscription

`SubscribeToTask` with `lastSeenGeneration=N` skips the snapshot and sends only newer
events. If the generation cannot be replayed, the server sends a snapshot. A
non-integer value is `-32602`.

```bash
curl -N -H 'A2A-Version: 1.1' "$BASE/tasks/$ID:subscribe?lastSeenGeneration=7"
```

## Write artifacts as a client

Declare `transport do user_artifacts true end` on the domain; the card then advertises
`capabilities.userArtifacts` and `SendMessageRequest.artifactUpdates` is accepted.
Without it, `artifactUpdates` answers `-32004`.

## Related configuration

- `config :ash_a2a, :events_transport` (or `execution: [events_transport: name]`):
  publishes `messageUpdate` events.
- `execution: [cancel_in_flight: :refuse]`, `execution: [validate_input_modes: false]`.

Details: [configuration](../reference/configuration.md).

## See Also

- [Endpoint contract](../reference/a2a-endpoint-contract.md)
- [Spec-version mapping](../reference/a2a-spec-version-mapping.md)
- [A2A v1.1 conformance](../reference/a2a-v1-1-conformance.md)
