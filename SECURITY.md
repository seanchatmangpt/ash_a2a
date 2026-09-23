# Security Policy

## Supported versions

`ash_a2a` uses calendar versioning (`YY.M.N`). Only the latest `26.9.x`
line on `main` receives security fixes; published Hex releases lag `main`
in this era, so check the [CHANGELOG](CHANGELOG.md) for which fixes a given
Hex version actually contains.

## Reporting a vulnerability

Open a GitHub issue at
<https://github.com/seanchatmangpt/ash_a2a/issues> describing the impact
and, if possible, a reproduction. This is a solo-maintained research-era
project; there is no private channel yet — do not include live credentials
in a report.

Include the module and refusal code if you hit one: the library fails
closed with typed `:REFUSED_*` / `:refused_*` vocabulary (see
`AshA2A.Semantic.Refusal` and `AshA2A.CapabilityIndex.Validator`), and
those codes make reports actionable quickly.

## Security model in one paragraph

Authentication and authority are separate decisions (RFC-SA2A-001 S29).
`A2A.Plug.Auth` verifies a credential and produces an identity map; that
identity — and never anything read from `A2A.Message.metadata` — becomes
`context.actor`/`context.tenant` inside Ash actions
(`AshA2A.ContextResolver`). Consequential skills (`:change`/`:external_do`)
additionally require a standing grant for the exact
`(principal, capability_id)` pair from `AshA2A.Authority.Grant`, consulted
through a configured broker; `:unknown`-consequence skills are refused
outright. Token validation itself is fully delegated to your `verify/3`
callback — the SDK ships no JWKS, introspection, or signature checking, and
mTLS is declared-but-unsupported at the plug layer. Details:
[the authentication how-to](docs/how-to/authenticate-agent-requests.md) and
[verifying authority on async paths](docs/how-to/verify-authority-on-async-paths.md).

## Operational security notes

- The default receipt store is in-memory; production durability wants
  `config :ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv` with a real
  `:data_dir` (the EKV default data dir is under the OS temp directory and
  is not guaranteed to survive a host reboot).
- A revoked-but-unexpired grant can still actuate from an already-enqueued
  async job unless your worker re-verifies with
  `AshA2A.Delivery.ObanAuthority.verify_live!/3` — see
  [the async authority how-to](docs/how-to/verify-authority-on-async-paths.md).
- The Kubernetes security posture of the swarm test harness (NetworkPolicy
  egress isolation, restricted Pod Security, non-root execution) and its
  measured evidence are documented in `docs/archive/reports/ENTERPRISE_READINESS_REPORT.md`
  and `docs/archive/reports/AIRGAP_READINESS_REPORT.md` (kind-cluster scope, 2026-09-15;
  image digest pinning remains a disclosed open item).
