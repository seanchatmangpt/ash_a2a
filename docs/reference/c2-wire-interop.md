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

- TLS transport: both framed clients accept
  `ctx.c2_tls` (`AshA2A.C2.L07Tls.Transport`): `verify_peer`, pinned CA, client certificate
  (mutual), hostname check; incomplete config or failed handshake is refused and never falls back
  to the unix socket. Test: `test/ash_a2a/c2/l07_tls_framed_test.exs` (unpinned-CA and hostname
  refusal; 5 passed, 2026-11-16, Elixir 1.20.4 / OTP 29.1.1) drives the transport only. The authority listener serves TLS 1.3 (`verify_peer`,
  `fail_if_no_peer_cert`, pinned CA, 64-connection cap) and, via `AUTHORITY_LISTEN_UNIX` plus
  `AUTHORITY_TLS_PORT`, alongside the UDS listener; tests with a real
  `:ssl` round trip and an unpinned-client-cert refusal:
  `authority_service/test/mtls_test.exs`, `authority_service/test/lane_w2_05_authority_hardening_test.exs`
  (both pass in `cd authority_service && mix test`, 66 passed).
  Remaining: no test yet drives the `lib/` framed client against that listener, and the
  actuator release's own TLS listener is not covered here.
- Approval collection for k > 0 classes.
  The control plane now has an approver channel: the `"approve"` wire op deposits a signed
  approval in `AuthorityService.ApproverChannel.Mailbox`, and the Issuer solicits it on `issue`
  and re-verifies it (distinct custodians, `(kid, nonce)` replay refused at deposit and by the
  journal). Tests: `authority_service/test/approver_mailbox_test.exs`. Remaining: the framed
  client in `lib/` does not yet send `"approve"`, `sa2a-approver` does not yet speak the op, and
  the mailbox, when wired by `Runtime` (`verify:` option), verifies each approval (signature
  against the registered key, standing, audience, custodian == slot approver, digest and
  generation == slot) before a slot or nonce is consumed and refuses `approval_invalid`;
  slots stay first-wins (test in
  `lane_w2_05_authority_hardening_test.exs`, passing). A mailbox started without `verify:` (tests
  only) still only holds data. Policy epoch and TTL are still checked only by the Issuer.
- The actuator profile requires the actuator's own effect vocabulary in `PreparedEffect.payload`;
  general `PreparedEffect`s are refused (`:payload_profile`).
- Red-team defects B1, B2, B3, T2, T3, T4 and the minor items are in `actuator/` and
  `authority_service/` and are not changed here (PR #65 did not touch those projects).
  Actuator: the optional mTLS listener
  (`Actuator.Wire.TLS`: TLS 1.3, `verify_peer`, `fail_if_no_peer_cert`, pinned CA) is started
  from the config `wire.tls` block. Its 64-connection cap is tested over real `:ssl` connections
  (`actuator/test/actuator/wire_tls_cap_test.exs`), and the T4 test now forces the interleaving
  with a store-process context fun that blocks on a message. Remaining: `authority_service/`
  items. The cap test needs `openssl`; it passed here (`cd actuator && mix test
  test/actuator/wire_tls_cap_test.exs`, 1 passed). The whole actuator suite ran 81/83: the two
  failures are `l10_red_team_test.exs` (UDS connection cap: a connection beyond the cap was
  answered) and `repair_test.exs` (unwritable anchor; the run was as root, which ignores file
  modes).

## See also

- `docs/reference/c2-certificate.md`
- `docs/reference/c2-compromise-court.md`
