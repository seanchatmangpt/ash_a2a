# c2-wire-interop

How the control-plane clients reach the separate `authority_service` and `actuator` releases,
what had to be reconciled, and what remains open. Last updated 2026-09-29 (v26.9.28).

## Contents

- Findings
- Reconciliation
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
   actuator executes.
2. Control plane: `AshA2A.C2.ActuatorProfile` (effect mapping and certificate conversions) and
   two framed clients, `AuthorityClient.Framed` (`:authority_socket`) and
   `ActuatorClient.Framed` (`:actuator_socket`). The actuator client re-derives the effect bytes
   and refuses to send when the certificate digest differs.
3. Actuator profile `PreparedEffect`: payload keys exactly
   `effect_type, consequence_class, effect_instance_id, resource_bounds, params`; `capability`
   and `subject` are the actuator's own strings.

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

- TLS transport is not implemented in the framed clients (UDS only).
- Approval collection for k > 0 classes: the framed authority client forwards `ctx.approvals`
  but the control plane has no approver channel of its own.
- The actuator profile requires the actuator's own effect vocabulary in `PreparedEffect.payload`;
  general `PreparedEffect`s are refused (`:payload_profile`).
- Red-team defects B1, B2, B3, T2, T3, T4 and the minor items are in `actuator/` and
  `authority_service/` and are not changed here (PR #65 did not touch those projects).

## See also

- `docs/reference/c2-certificate.md`
- `docs/reference/c2-compromise-court.md`
