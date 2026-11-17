# c2-wire-interop

How the control-plane clients reach the separate `authority_service` and `actuator` releases,
what had to be reconciled, and what remains open. Last updated 2026-09-30 (v26.9.30).

## Contents

- Findings
- Reconciliation
- Policy evidence (AuthZEN PDP)
- Proof
- Open gaps

## Findings

| surface | merged control plane (PR #65) | separate releases |
|---|---|---|
| transport | HTTP JSON via `Req.post` to `:authority_endpoint` / `:actuator_endpoint` | authority: `<<len::32, json>>` on a unix socket or mTLS; actuator: 4-byte-length JSON on UDS or mTLS; no HTTP |
| authority reply | `{"decision": "admit", "certificate": ...}` | `{"ok": true, "certificate": {"envelope", "message"}}` or `{"ok": false, "refusal"}` |
| effect | five-key `PreparedEffect` view, digest over that view | authority parsed `effect_class` + `amount`; actuator required an exact 10-key set and refused `effect_class`/`amount` |
| certificate | `version`, ms times, `threshold` | seconds, `v`, per-signature kid/alg/nonce |

The HTTP remote clients (`AuthorityClient.Remote`, `ActuatorClient.Remote`) cannot talk to the
releases (different transport, framing and reply shape) and are left intact for their own tests.

## Reconciliation

Smallest change on each side:

1. `authority_service` `Issuer` derives the policy class from an actuator-shaped effect
   (`consequence_class`, tier amount 0) as well as from `effect_class`/`amount`. Unknown classes
   still refuse. One canonical byte string is now what the authority certifies and what the
   actuator executes. `Issuer.to_actuator_certificate/1` maps `{envelope, message}` to the
   actuator's `signatures: [...]` certificate form (`cd authority_service && mix test`,
   66 passed, 2026-11-16, Elixir 1.20.4 / OTP 29.1.1).
2. Control plane: `AshA2A.C2.ActuatorProfile` (effect mapping and certificate conversions) and
   two framed clients, `AuthorityClient.Framed` (`:authority_socket`) and
   `ActuatorClient.Framed` (`:actuator_socket`). The actuator client re-derives the effect bytes
   and refuses to send when the certificate digest differs.
3. Actuator profile `PreparedEffect`: payload keys exactly
   `effect_type, consequence_class, effect_instance_id, resource_bounds, params`; `capability`
   and `subject` are the actuator's own strings.

## Policy evidence (AuthZEN PDP)

Below the authority boundary, the control plane can absorb evidence from an external policy
decision point speaking the OpenID AuthZEN Authorization API 1.0 evaluation
(`AshA2A.C2.PolicyEvidence`, commits 04eec80/42671ef):

- `PolicyEvidence` is pure and offline: `sarc_request/1` builds the AuthZEN SARC request
  (subject/action/resource/context) for an `AuthorityRequest`; `from_response/4` binds a PDP
  response to the exact request it answered and refuses `:pdp_mismatch` unless the discovered
  metadata names the configured PDP identifier, `:pdp_not_https`/`:pdp_endpoint_not_https`
  for non-HTTPS endpoints, and `:decision_malformed` unless `decision` is a strict JSON
  boolean (unknown metadata keys are ignored). `binds?/2` re-checks the
  digest/principal/policy-epoch/revocation-epoch/generation fence, and
  `grants_do_authority?/1` is always `false`: an `:allow` is an input to
  `AshA2A.C2.AuthorityService.authorize/3`, never a substitute for it.
- `PolicyEvidence.PdpClient` is the Req-based PEP side: it discovers the PDP via
  `GET /.well-known/authzen-configuration`, requires HTTPS, disables redirects so a response
  cannot come from a PDP other than the configured identifier, and POSTs the SARC request to
  the metadata's `access_evaluation_endpoint`.
- `AuthorityService.authorize/3` makes the evidence opt-in via ctx opts
  `policy_evidence_required` / `policy_evidence`: when required, a `:allow` evidence bound to
  the exact request must be present, else the refusals `:policy_evidence_missing` /
  `:policy_evidence_mismatch`; it never replaces `policy.admit/2` or certificate issuance.
- The AuthZEN wire request `action` now emits the canonical Authorization API 1.0 shape
  `{"name": ..., "properties": ...}` (c3a4be8/ca2e43f) instead of the entity
  `{"type": ..., "id": ...}` projection.
- `PolicyEvidence.McpProjection.project/2` projects an MCP `tools/call` request (the COAZ-MCP
  shape) into a powerless `PreparedEffect` with capability id `mcp.tool:<name>` (6226254);
  the principal comes from the authenticated caller, never from tool arguments; non-map
  `arguments` refuse `:mcp_arguments_malformed`.

## Proof

`test/ash_a2a/c2/framed_interop_test.exs` (tags `:serial, :serial_solo, :c2_interop`) starts the real
authority and actuator releases as separate OS processes (production entrypoints, no Erlang
distribution) and drives `ActuationPipeline.execute/4` with the framed clients:
prepared effect, authority issue, canonical certificate, actuator execute, ledger entry read from
disk. It also checks replay (`replayed`, one ledger entry), single issuance
(`already_issued`), digest binding, flipped-signature refusal by the actuator, and subject
allow-list refusal. Unit coverage: `test/ash_a2a/c2/certificate_model_test.exs`,
`authority_service/test/authority_service_test.exs`.

## Open gaps

- Authority to actuator, end to end: closed. The C2 compromise court runs the real
  `authority_service` release build and the real actuator as separate OS processes; a
  certificate the authority issued for an actuator-shaped effect, converted with
  `Issuer.to_actuator_certificate/1`, is executed by the actuator's production entrypoint
  (registry = the authority key, quorum 1): `performed`, replay `replayed`, one ledger entry
  (`compat[0]` in `tmp/c2_court/report.json`, asserted by
  `test/ash_a2a/c2_compromise/c2_compromise_court_test.exs`, 12 passed, 2026-11-17). Found on
  the way: the authority's service key carried revocation epoch 0 unconditionally, which an
  actuator with an advanced revocation view refuses; set `AUTHORITY_KEY_REVOCATION_EPOCH` to
  the epoch the actuator's view is at. A policy must also name the actuator's consequence
  classes or the issuer answers `unknown_effect_class`.
- TLS transport: both framed clients accept
  `ctx.c2_tls` (`AshA2A.C2.L07Tls.Transport`): `verify_peer`, pinned CA, client certificate
  (mutual), hostname check; incomplete config or failed handshake is refused and never falls back
  to the unix socket. Test: `test/ash_a2a/c2/l07_tls_framed_test.exs` drives the transport only.
  The authority listener serves TLS 1.3 (`verify_peer`, `fail_if_no_peer_cert`, pinned CA,
  64-connection cap) and, via `AUTHORITY_LISTEN_UNIX` plus `AUTHORITY_TLS_PORT`, alongside the
  UDS listener; tests with a real `:ssl` round trip and an unpinned-client-cert refusal:
  `authority_service/test/mtls_test.exs`, `authority_service/test/lane_w2_05_authority_hardening_test.exs`.
  The actuator's TLS listener is covered by `actuator/test/actuator/wire_tls_cap_test.exs` and
  by the court's mTLS attacks. Remains: no test drives the `lib/` framed clients against either
  release's TLS listener, because the court speaks the wire with its own harness client.
- Approval collection for k > 0 classes.
  The control plane has an approver channel: the `"approve"` wire op deposits a signed
  approval in `AuthorityService.ApproverChannel.Mailbox`, and the Issuer solicits it on `issue`
  and re-verifies it (distinct custodians, `(kid, nonce)` replay refused at deposit and by the
  journal). The mailbox, when wired by `Runtime` (`verify:` option), verifies each approval
  (signature against the registered key, standing, audience, custodian == slot approver, digest
  and generation == slot) before a slot or nonce is consumed and refuses `approval_invalid`;
  slots stay first-wins. Tests: `authority_service/test/approver_mailbox_test.exs`,
  `lane_w2_05_authority_hardening_test.exs`. A mailbox started without `verify:` (tests only)
  still only holds data. Remains: the framed client in `lib/` does not send `"approve"` and
  `sa2a-approver` does not speak the op (neither exists yet as code to test); the court attaches
  approvals to the `issue` request instead. Policy epoch and TTL are checked only by the Issuer.
- The actuator profile requires the actuator's own effect vocabulary in `PreparedEffect.payload`;
  general `PreparedEffect`s are refused (`:payload_profile`). By design.
- Listener connection caps: closed. Every listener (`Actuator.Wire.UDS`, `Actuator.Wire.TLS`,
  `AuthorityService.Listener` unix and TLS) sets a listen backlog of 256, four times its
  64-connection cap, so a burst is decided by the cap and not dropped by the kernel accept
  queue. A connection over the cap gets one `too_many_connections` refusal frame and is closed;
  the actuator's TLS listener closes it before the handshake instead. Burst tests open cap + 32
  bare connections and assert exactly 64 served and 32 refused, in arrival order:
  `actuator/test/actuator/l10_red_team_test.exs`, `actuator/test/actuator/wire_tls_cap_test.exs`,
  `authority_service/test/lane_w2_05_authority_hardening_test.exs` (unix and TLS). The TLS burst
  test exposed a leak: `:ssl.close/1` refuses a transport-accepted socket, so over-cap TLS
  connections had been left open until the peer gave up; they are now dropped with a
  zero-timeout handshake.
- Red-team defects B1, B2, B3, T2, T3, T4 are in `actuator/` and `authority_service/`; their
  regressions run in the child suites: `cd actuator && mix test` 85 passed,
  `cd authority_service && mix test` 68 passed (2026-11-17, Elixir 1.20.4 / OTP 29, `openssl`
  present). The T4 test forces the interleaving with a store-process context fun that blocks
  on a message.
