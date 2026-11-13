# SPIFFE absorption — RFC Factory D

Status: semantic donor qualification; not an authority substitution.

## Donor contract

SPIFFE contributes workload identity, trust-domain-qualified identity, short-lived SVIDs, rotating trust bundles, workload-local credential delivery, and federated trust-domain verification. Prefer X.509-SVID for protected Authority↔Actuator transport; JWT-SVID remains a compatibility edge with replay risk.

Canonical composition:

```
SPIFFE_ID + SVID + trust_bundle
  -> authenticated workload principal
  -> AuthZEN PolicyEvidence
  -> SA2A PreparedEffect / exact principal
  -> ActuationCertificate
  -> actuator-local claim
  -> DO
  -> receipt / replay / standing
```

SPIFFE authentication MUST NOT imply authorization, ActuationCertificate issuance, resource allocation, or DO.

## Reverse Chesterton / retained negative knowledge

1. Trust domains are cryptographic identity namespaces, not labels.
2. SVID validity is relative to the matching trust-domain bundle.
3. Workload credentials are obtained locally; control-plane configuration does not carry actuator private keys.
4. X.509-SVIDs are preferred where replay resistance matters; JWT bearer material requires an explicit replay threat treatment.
5. Bundle/key rotation is normal state, therefore verifier state cannot assume a permanent root key.
6. Multiple identities are possible; selecting a convenient/default identity must never silently change the SA2A principal.
7. Federation expands authentication reach, not authority.
8. A valid SVID from an independent trust domain is evidence for signer independence only when certificate policy separately binds that trust domain.

## Qualification courts

| Court | Falsifier |
|---|---|
| identity_is_not_authority | valid SVID reaches DO without ActuationCertificate |
| domain_bundle_binding | SVID validates under a bundle for another trust domain |
| principal_preservation | SPIFFE ID changes between policy evidence and PreparedEffect/certificate |
| no_ambient_control_credentials | control plane can read actuator private key material |
| rotation_survival | legitimate bundle rotation permanently bricks verification |
| stale_bundle_fail_closed | removed/revoked trust material remains sufficient for protected DO |
| jwt_replay_containment | replayed JWT-SVID alone yields a second protected DO |
| federation_not_authority | federated identity obtains authority solely due to federation |
| multi_identity_no_default_confusion | identity ordering/hint silently changes consequential principal |
| trust_domain_independence | duplicate signer domains satisfy distinct-domain quorum |

## Ownership

- SPIFFE/SPIRE: workload authentication and credential lifecycle.
- AuthZEN adapter: policy decision evidence.
- ash_a2a: exact principal/effect semantics and consequence gate.
- wasm4pm actuator/security: certificate verification, fencing, local claim/completion, protected DO.
- BCINR/CMCA: allocation mathematics only.
- receipts/courts: replay and standing.

## Absorption result

The imported capability is stronger after composition: SPIFFE's workload authentication gains exact effect binding, authorization separation, generation/epoch fencing, resource conservation, durable claims, receipts and replay without replacing SPIFFE's mature credential lifecycle.

Source horizon: SPIFFE latest specifications observed 2026-09-29; bind implementation/library versions separately before runtime dependency admission.
