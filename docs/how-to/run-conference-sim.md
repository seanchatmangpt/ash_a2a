# How to run the conference-sim court suite

## Overview

`test/conference_sim/` models a real AGNTCon+MCPCon conference (3,500
attendees / 150 talks / 11 tracks / 7 workshops / exhibitor booths with MCP
servers / registration tiers / badge scanning) built entirely from REAL
ash_a2a machinery: real `AshA2A.Protocol.Agent` GenServers under a real
`AshA2A.Protocol.AgentSupervisor`, real Ash (ETS) resources, real signed
badge cards, real session tasks, real push-config deliveries, and real
Bandit HTTP/gRPC servers on the wire. No mocks or patches anywhere in the
family.

The suite is the conference court: every capability the venue needs is
proven on the real pipeline under event-scale conditions.

## Running locally

```console
# Whole family: the shared fixture plus every court file. This is the exact
# invocation CI runs (see .github/workflows/ci.yml, `conference-sim` job).
MIX_ENV=test mix test test/conference_sim/fixture_test.exs \
  test/conference_sim/*_court.exs

# One court:
MIX_ENV=test mix test test/conference_sim/governance_court.exs

# Load court at a lower scale on a small machine (the court reports what WAS
# achieved and asserts the achieved count EQUALS the configured scale, never
# silently fewer):
CONFERENCE_SIM_LOAD_SCALE=25 MIX_ENV=test mix test \
  test/conference_sim/load_court.exs
```

Note: the court files are named `*_court.exs`, which ExUnit's default
`*_test.exs` pattern does not collect — pass the explicit paths (as above)
or run the whole directory plus the fixture explicitly. Only
`fixture_test.exs` is collected by a bare `mix test`.

## What each court family proves

| Court file | Lane | Proves |
|---|---|---|
| `fixture_test.exs` | EV1 | The shared AGNTCon fixture: real agents, ETS Ash resources, signed badge issuance through the real dispatch path, session task fan-out as push-config deliveries and subscriber events, teardown with no port leaks. |
| `registration_court.exs` | EV2 | Registration as a commerce path (entitlement law): tier entitlements are bound to the paying attendee; forged/escalated tiers are refused; granted wire responses echo the correlation id. |
| `exhibitor_signing_court.exs` | EV3 | Card-signing under event conditions: exhibitors sign their served agent cards with real `CardSigning` (`kid`-pinned venue key); forged and rotated-key cards are refused on verification. |
| `auth_tier_court.exs` | EV4 | The A2A v1 security-scheme surface as venue tiers: apiKey badge scan -> expo, HS256 bearer -> workshop, oauth2 (real RFC 7662 + client-credentials) -> VIP, openIdConnect (RS256 + JWKS discovery) -> SSO; tier policy enforced on the real `Plug.Auth` middleware over real Bandit HTTP. |
| `push_court.exs` | — | Push-config lifecycle under event conditions: registration, delivery through a real recording sender, resubscribe. |
| `multitrack_stream_court.exs` | — | Parallel-track streaming through real task-store fan-out and subscriber events without cross-track interference. |
| `networking_court.exs` | — | Venue networking: attendees discover and message each other over the real dispatch path. |
| `observability_court.exs` | — | Telemetry/OCEL event emission and receipts observable on the real stores under event conditions. |
| `load_court.exs` | EV9 | Conference-scale concurrency at honest 1/35th scale: `CONFERENCE_SIM_LOAD_SCALE` (default 100) concurrent attendee-agents racing registration, session creation, stream subscriptions, and a mixed workload; timing assertions are floors, never ceilings. |
| `red_team_court.exs` | EV10 | The hostile attendee at event scale: badge forgery (attacker RSA key vs real JWKS), badge replay after `exp`, tier escalation, session/push hijack, 200-connection stream bombing with the venue surviving, metadata clobber re-check, unauthenticated gRPC refused — each attack paired with an honest positive control. |
| `grpc_venue_court.exs` | — | The venue over the real gRPC binding: venue methods served by a real gRPC server; with the auth interceptor configured, unauthenticated calls get UNAUTHENTICATED(16) while honest attendees are served. |
| `workshop_court.exs` | — | Workshop tasks: real `:input_required`-paused session tasks continued on update; capacity-bounded workshop seats. |
| `governance_court.exs` | — | Venue governance on the real refusal path: conduct-flag refusal (`CONDUCT_VIOLATION`), tombstone and suspend semantics. |
| `interop_court.exs` | EV14 | Cross-vendor interoperability: the ash_a2a venue accepts a signed credential issued by a second vendor's stack (ash_affidavit) — two identities, one wire. |

## Nightly-tier recommendation for the load court (EV9)

The per-PR run keeps the default `CONFERENCE_SIM_LOAD_SCALE=100` (about
1/35th of the 3,500-attendee headline). That is a rehearsal claim, not a
capacity claim: venue-scale numbers need venue-scale load, and CI cannot
rehearse 3,500 simultaneous attendees. Recommendation: keep the per-PR court
at the default 100 and run a **nightly** job at a higher scale, bounded by
runner resources:

```console
CONFERENCE_SIM_LOAD_SCALE=500 MIX_ENV=test mix test \
  test/conference_sim/load_court.exs
```

Same shape as the mutation court's nightly tier (see
[run-mutation-testing.md](run-mutation-testing.md)): its own scheduled
workflow, e.g. `cron: "0 7 * * *"`, `CONFERENCE_SIM_LOAD_SCALE=500 MIX_ENV=test
mix test test/conference_sim/load_court.exs`, with failures durable as
artifacts. Even 500 stays a rehearsal (1/7th scale) — the capacity claim for
3,500 remains `UNKNOWN` until a venue-scale run exists.
