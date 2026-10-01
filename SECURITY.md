# Security Policy

## Supported versions

`ash_a2a` uses calendar versioning (`YY.M.N`). Security fixes land on `main`
and ship in the next Hex release; only the newest published Hex version is
supported.

| Version | Supported | Notes |
|---|---|---|
| latest `26.9.x` on Hex | yes | fixes are backported only to the newest release |
| older `26.9.x` | no | upgrade to the newest release |
| `main` (unreleased) | best effort | may be ahead of Hex; see [CHANGELOG](CHANGELOG.md) |

The [CHANGELOG](CHANGELOG.md) names the first Hex version that carries each
security fix (and its GHSA/CVE id once one is assigned).

## Reporting a vulnerability

**Do not open a public issue for a vulnerability.** Report it privately
through GitHub Private Vulnerability Reporting:
<https://github.com/seanchatmangpt/ash_a2a/security/advisories/new>.
Include the impact, affected version or commit SHA, and a reproduction if
possible. Never include live credentials.

If that form is unavailable (Private Vulnerability Reporting disabled or the
link returns an error), open a public issue titled `Security contact request`
that contains **no** vulnerability details; the maintainer will open a
private advisory and invite you to it.

Response targets (solo maintainer, best effort, business days):

| Step | Target |
|---|---|
| Acknowledge the report | 3 business days |
| Triage and severity (CVSS v4) | 7 business days |
| Fix released: critical / high | 14 / 30 days |
| Fix released: medium / low | 90 days / next release |

Disclosure process: the fix is developed in a private GitHub security
advisory, a GHSA (and a CVE through GitHub's CNA when warranted) is
requested, the fixed Hex version is published, and the advisory is then made
public with credit to the reporter unless they ask otherwise. The default
coordinated-disclosure window is 90 days from the report.

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

Production hardening checklist (see
[the configuration reference](docs/reference/configuration.md) for each key):

- **Security profile (RFC-SA2A-007).** `config :ash_a2a, :security_profile,
  :strict | :legacy_compat | :dev_bypass`, set in build config and read with
  `Application.compile_env/3`; the default is `:strict`. It is never taken
  from call options, request data or runtime env. `:dev_bypass` is opt-in,
  compiled out of `:prod` builds (requesting it there is a `CompileError`),
  prints a boot banner, emits `[:ash_a2a, :security_profile, :dev_bypass]`
  and is stamped on receipts via `AshA2A.SecurityProfile.stamp/1`.
  `config/runtime.exs` is a prod-like template for `:strict`.
- **What boot enforces.** `AshA2A.Application.start/2` calls
  `AshA2A.SecurityProfile.Boot.run!/0` before any child starts, against the
  profile compiled into the build. Under `:strict` it raises
  `AshA2A.Authority.SecurityPreflight.Error` listing every violation of:
  `:receipt_outbox_key`/`:receipt_binding_key` set (`outbox_key_missing`);
  `:receipt_outbox_dir` set and not under a tmp path (`outbox_dir_not_durable`);
  `:receipt_store` not `AshA2A.ReceiptStore.Memory` (`receipt_store_in_memory`);
  `:capability_release_mode` equal to `:strict`
  (`capability_release_mode_legacy`); an `:authority_broker` configured
  (`authority_broker_missing`); `:kill_switch_class` non-nil
  (`kill_switch_class_missing`); and `:authority_policy` not
  `:transport_verified_grants_capability`
  (`transport_verified_policy_forbidden`); the outbox/journal HMAC key shorter than
  32 bytes (`outbox_key_weak`); and the claim store: `:claim_store` unset
  (`claim_store_missing`), in-memory/ETS or non-durable
  (`claim_store_not_durable`), or a durable-file store whose `:claim_store_dir` is
  unset or under a tmp path (`claim_store_dir_not_durable`). It then runs
  `AshA2A.Authority.SecurityPreflight.check!(force: true)` and
  `AshA2A.ReceiptStore.boot_check/0`. `:legacy_compat` logs the same strict
  violations as warnings (it does not raise on them), still applies the
  ordinary `SecurityPreflight` rules, and raises on a failing
  `ReceiptStore.boot_check/0` only when `:production` is true. `:dev_bypass`
  prints a banner, applies only the ordinary preflight and a non-raising
  store check, and never conforms. Boot checks configuration presence and
  shape only: it does not verify credentials, broker contents, key strength,
  or that the configured store is reachable beyond `boot_check/0`. Boot
  enforcement is not a conformance claim: C1, C2 and C3 are claimed only by
  `mix ash_a2a.verify_conformance --profile cN` on a clean, exact subject
  (see `docs/reference/conformance-claim.md`). Courts:
  `test/ash_a2a/security_profile/boot_test.exs` (strict refuses each
  violation, system tmp outbox refused, dev_bypass banner and telemetry, code
  classification). No court yet asserts that `Application.start/2` itself
  refuses to boot under a violating strict config.
- `config :ash_a2a, :strict_security, bool` still overrides
  `SecurityPreflight.strict?/0` (otherwise it follows the profile).
- Leave `config :ash_a2a, :require_authenticated_caller` at its default
  `true`; opt individual skills out with `public_skills:` only when they are
  meant to be anonymous.
- Keep `config :ash_a2a, :semantic_max_text_bytes` bounded (default 16_384)
  if the semantic surface is enabled.
- Never set `:allow_legacy_authority_policy` in production.
- Bound request bodies at the endpoint (`Plug.Parsers`, `length:`).

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
