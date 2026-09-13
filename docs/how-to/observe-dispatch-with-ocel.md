# How to get OCEL v2 process-mining evidence for every A2A dispatch

This guide shows how to forward every `AshA2A.Dispatcher` skill dispatch as an
OCEL v2 event to an external process-mining ingest endpoint, using the real
`AshA2A.Telemetry.OcelForwarder` module.

Before you start: this is **best-effort observational telemetry riding the
existing dispatch span**, not a mandatory receipt or admission boundary. If
you need a receipt that participates in identity/authority/replay/standing,
that is `AshA2A.CommandBus` (see the explanation doc on Authority/CommandBus)
— a separate, opt-in path that is *not* wired into `AshA2A.Agent`'s default
`call/2` dispatch. `OcelForwarder` never blocks, never raises into the caller,
and never affects what a dispatch returns.

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

## 2. Attach the handler

Call `AshA2A.Telemetry.OcelForwarder.attach!/0` once, typically from your
application's `start/2`:

```elixir
def start(_type, _args) do
  :ok = AshA2A.Telemetry.OcelForwarder.attach!()
  # ... your supervision tree
end
```

`attach!/0` attaches two `:telemetry` handlers:

- `[:ash_a2a, :dispatch, :stop]` — fired by `AshA2A.Dispatcher`'s existing
  `:telemetry.span([:ash_a2a, :dispatch], ...)` around every skill dispatch.
  No new instrumentation at any call site is required; the span already
  exists in `dispatcher.ex`.
- `[:ash_a2a, :receipt, :committed]` — fired when a `CommandBus`-mediated
  command commits a real `AshA2A.Receipt`, forwarded via
  `AshA2A.SemanticProjection.ocel_event/1`. This only fires on the
  `CommandBus` path, so a plain `AshA2A.Agent.call/2` dispatch will never
  emit it.

Call `AshA2A.Telemetry.OcelForwarder.detach/0` to remove both handlers (e.g.
in test `on_exit/1` callbacks).

## 3. What a forwarded dispatch event looks like

For a plain skill dispatch (e.g. `AshA2A.Dispatcher.dispatch(:run_phase,
message, Facilitator)`), the forwarded JSON event has this shape:

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

## 4. Verifying it works

The real integration test,
`test/ash_a2a_telemetry_ocel_forwarder_test.exs`, spins up a real local
Bandit HTTP listener mirroring the ingest contract, dispatches a real
`AshA2A.Dispatcher.dispatch/5` call against the `FreedomGym.Facilitator`
fixture, and asserts on the actual captured HTTP body — no mocks. Run it
directly to confirm forwarding works in your environment:

```
mix test test/ash_a2a_telemetry_ocel_forwarder_test.exs
```

Any non-2xx ingest response or a network failure is logged via
`Logger.warning/1` and swallowed — dispatch itself always succeeds or fails
independently of whether the OCEL event was delivered.
