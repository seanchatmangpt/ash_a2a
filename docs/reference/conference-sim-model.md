# Conference Sim Model

Reference for the conference simulation (`test/conference_sim/`): a synthetic
AGNTCon + MCPCon event executed entirely over the real A2A v1 protocol
surface. The event is the domain; the protocol is the physics.

## The Event Model

AGNTCon + MCPCon: 3,500 attendees, 150 talks, 11 tracks, exhibitor MCP booths,
workshops, and registration tiers. Each event concept maps to an A2A v1
entity:

```text
attendee            -> agent (real process, signed agent card badge)
session / talk      -> streaming task (SSE message/stream)
workshop            -> input-required task lifecycle
badge               -> signed agent card (JWT, venue JWKS)
registration        -> entitlement (tier -> auth scopes)
exhibitor booth     -> MCP server (call_tool skill on a real agent)
networking          -> agent-to-agent messaging over the venue registry
governance          -> typed scope refusals (CONDUCT_VIOLATION,
                       RESIDENCY_REGION_LOCK, RECORDING_CONSENT_REQUIRED,
                       SPONSOR_SCOPE_REQUIRED)
```

Nothing is an in-memory stub. Attendees are real OS processes, badges are
really signed, sessions are real tasks with real push configs and SSE
subscriptions.

## Court Families

Each `.exs` file is a court: a falsifier corpus over one event property.

| Court | Event property | Formal object |
|---|---|---|
| `auth_tier_court.exs` | badge scan / tier admission | admission boundary |
| `exhibitor_signing_court.exs` | badge + card authenticity | admission boundary (JWKS, rotation) |
| `governance_court.exs` | conduct, residency, consent | boundary cohomology (typed refusals) |
| `networking_court.exs` | agent-to-agent messaging | boundary cohomology (privacy, ordering) |
| `multitrack_stream_court.exs` | concurrent streams | event ordering law (Last-Event-ID replay) |
| `push_court.exs` | rescheduling push deliveries | event ordering law (signed push) |
| `grpc_venue_court.exs` | JSON-RPC / gRPC / REST parity | admission boundary (one store) |
| `workshop_court.exs` | interactive lifecycle honesty | event ordering law (no phantom terminal) |
| `load_court.exs` | bounded-scale concurrency | admission boundary at scale |
| `observability_court.exs` | attendee journey trace | observability surface (OCEL-style log) |
| `fixture_test.exs` | fixture self-proof | admission boundary (real venue fixture) |

## Honest Scope

Simulated: protocol behavior at bounded scale (10-13 live agents, ~100-200
concurrent operations), real signing, real transport, real task store.

Not simulated: a physical venue, 3,500 real processes, paid registration, or
any production load. The tier model is entitlement semantics, not billing.

## Thesis Tie

The event is the receipt calculus in costume. Registration is observation
admission (`O*`): a tier is an admitted observation of the attendee.
The event program is manufacture: `mu` over admitted registrations. Badges,
session streams, and push deliveries are the receipts (`R`) of that
manufacture — each is a verifiable, replayable consequence bound to an
identity (badge JWT kid, task id, push config token). Standing is the tier
model: keynote/backstage access is standing over edges, and a 403 with a
typed envelope is a refusal that preserves the standing vocabulary rather
than an untyped error.

## See Also

`docs/reference/a2a-v1-conformance.md` · `docs/reference/telemetry.md` ·
`test/conference_sim/fixture.ex`
