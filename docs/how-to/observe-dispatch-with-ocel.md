# How to get OCEL v2 process-mining evidence for every A2A dispatch

This guide shows how to forward every `AshA2A.Dispatcher` skill dispatch as an
OCEL v2 event to an external process-mining ingest endpoint, using the real
`AshA2A.Telemetry.OcelForwarder` module.

Before you start: this is **best-effort observational telemetry riding the
existing dispatch span**, not a mandatory receipt or admission boundary. If
you need a receipt that participates in identity/authority/replay/standing,
that is `AshA2A.CommandBus` (see [Architecture](../explanation/architecture.md))
— and as of v26.9.14 it **is** the default route `AshA2A.Agent`'s `call/2`
dispatch takes for any `:change`/`:external_do`-consequence skill (only
`:observe`/`:read` skills stay off it). `OcelForwarder` never blocks, never
raises into the caller, and never affects what a dispatch returns.

## 1. Configure an ingest URL

`OcelForwarder` reads its target from application config. No URL, no
forwarding — every event handler becomes a silent no-op:

```elixir
# config/runtime.exs (or config/config.exs)
config :ash_a2a,
  ocel_ingest_url: "http://127.0.0.1:22000",
  ocel_ingest_timeout_ms: 2_000  # optional, defaults to 2_000
```

The forwarder POSTs to `"#{ocel_ingest_url}/ocel/events"` with a JSON body of
`%{"events" => [event]}` — one event per POST, matching beam4pm's
`BeamPM.OcelIngest.Router` wire contract.

## 2. Attachment is automatic

Since v26.9.15, `AshA2A.Application` (the library's own OTP `mod`) calls
`AshA2A.Telemetry.OcelForwarder.attach!/0` at boot — the call is
idempotent and a no-op cost when no ingest URL is configured — so a host
app gets forwarding the moment it sets `:ocel_ingest_url`. You do not
need to call `attach!/0` yourself (doing so is still harmless).

`attach!/0` attaches three `:telemetry` handlers:

- `[:ash_a2a, :dispatch, :stop]` — fired by `AshA2A.Dispatcher`'s existing
  `:telemetry.span([:ash_a2a, :dispatch], ...)` around every skill dispatch.
  No new instrumentation at any call site is required; the span already
  exists in `dispatcher.ex`.
- `[:ash_a2a, :receipt, :committed]` — fired when a `CommandBus`-mediated
  command commits a real `AshA2A.Receipt`, forwarded via
  `AshA2A.SemanticProjection.ocel_event/1`. As of v26.9.14 this is the
  default `AshA2A.Agent.call/2` route for any `:change`/`:external_do` skill
  (not opt-in-only anymore) — a plain agent call for a mutating skill emits
  this event.
- `[:ash_a2a, :receipt, :outboxed]` — fired when the command's `:pending`
  receipt is journaled to the `AshA2A.ReceiptOutbox` before dispatch
  (crash-recovery evidence; see
  [Architecture](../explanation/architecture.md)).

Per-event HTTP POSTs run under a bounded `Task.Supervisor`
(`config :ash_a2a, :ocel_max_in_flight`, default 256). Beyond that ceiling
the forwarder sheds deliberately, counts the shed, and reports it via the
`[:ash_a2a, :ocel, :shed]` event — observational egress is never an
unbounded process fan-out.

Call `AshA2A.Telemetry.OcelForwarder.detach/0` to remove all three
handlers (e.g. in test `on_exit/1` callbacks).

## 3. One event per dispatch, not two (deduplication)

A `CommandBus`-routed dispatch internally still calls
`AshA2A.Dispatcher.dispatch/6` (the same function a direct, non-CommandBus
caller uses), which still carries the `[:ash_a2a, :dispatch, :stop]` span.
Rather than posting that span as a second, separate OCEL event, `CommandBus`
marks the calling process for the duration of that internal call, and
`OcelForwarder` merges the dispatch span's fields
(`skill_name`/`reply_type`/`duration_native`/`relationships`) into the single
`[:ash_a2a, :receipt, :committed]` event instead of posting both — you get
exactly one real HTTP-posted event per logical CommandBus-routed dispatch,
carrying both receipt-derived fields (`capability_id`, `consequence`,
`status`, `command_id`, `execution_id`, `fingerprint`, `principal_id`,
`replayed`, and — when SPG identity is provided — `spg_graph_id`,
`spg_graph_version`, `spg_node_id`, `spg_edge_id`,
`spg_projection_family`) and the dispatch-derived ones. A direct, non-CommandBus
`AshA2A.Dispatcher.dispatch/6` call (e.g. a `:observe`/`:read` skill, or a
caller that bypasses the default agent path entirely) is unaffected and
still posts its own single dispatch event exactly as before.

## 4. What a forwarded dispatch event looks like

For a plain, non-CommandBus skill dispatch (e.g.
`AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator)`, or any
`:observe` skill through the default agent path), the forwarded JSON event
has this shape:

```json
{
  "event_id": "0192f...",
  "event_type": "ash_a2a.dispatch.facilitator.run_phase",
  "event_time": "2026-09-12T18:04:22.001Z",
  "attributes": {
    "skill_name": "run_phase",
    "resource_or_domain": "AshA2A.Test.Fixture.FreedomGym.Facilitator",
    "reply_type": "reply",
    "duration_native": "812000"
  },
  "relationships": []
}
```

`event_type` is `"ash_a2a.dispatch.<resource short name>.<skill_name>"`.
`relationships` is `[]` unless the dispatcher resolved a real object identity
for the call (a persisted Ash record's primary key, or a real `plan_name`
argument for a stateful plan skill) — it is never fabricated. When present it
looks like:

```json
"relationships": [
  {"qualifier": "acted_on", "object_id": "ocel_forwarder_relationships_test_1"}
]
```

On a dispatch `:exception` stage, `attributes` also carries `"stage"` and
`"error"` (an `inspect/1` of the raised error).

## 5. Verifying it works

Two real integration tests, no mocks:

- `test/ash_a2a_telemetry_ocel_forwarder_test.exs` — a real local Bandit HTTP
  listener mirroring the ingest contract, a direct
  `AshA2A.Dispatcher.dispatch/6` call against the `FreedomGym.Facilitator`
  fixture, asserting on the actual captured HTTP body for the single
  dispatch-only event.
- `test/ash_a2a_telemetry_ocel_forwarder_command_bus_test.exs` and
  `test/ash_a2a_ocel_default_path_sink_test.exs` — the same real pattern
  through `AshA2A.CommandBus.run/4` and the default `AshA2A.Agent` path,
  asserting exactly one merged event reaches the sink (proving the
  deduplication in step 3 above).

Run them directly to confirm forwarding works in your environment:

```
mix test test/ash_a2a_telemetry_ocel_forwarder_test.exs test/ash_a2a_telemetry_ocel_forwarder_command_bus_test.exs test/ash_a2a_ocel_default_path_sink_test.exs
```

Any non-2xx ingest response or a network failure is logged via
`Logger.warning/1` and swallowed — dispatch itself always succeeds or fails
independently of whether the OCEL event was delivered.
