# AuthorityService Kubernetes Manifests

Issue-only AuthorityService (RFC-SA2A-006 s7.4/s13) in its own namespace
`authority-system`. Source: `authority_service/` (separate OTP release, depends only on
`sa2a_crypto`). Hand-authored, following the conventions of `k8s/` and `swarm/`; no
generator was run. Last Updated: 2026-09-29 (v26.9.29).

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `authority-system`, Pod Security `restricted` (enforce/warn/audit) |
| `network-policy.yaml` | default-deny ingress+egress; ingress only on 8443 from `actuator-system` and `control-plane` |
| `statefulset.yaml` | 1 replica, non-root, `readOnlyRootFilesystem`, all caps dropped, no API token |
| `service.yaml` | ClusterIP 8443 (mutual TLS) |
| `service-account.yaml` | dedicated SA, zero RBAC, `automountServiceAccountToken: false` |
| `resource-quota.yaml` | namespace DoS bound |
| `kustomization.yaml` | image digest pin (placeholder) |

## Secrets and configuration (never committed)

```sh
# 32 random bytes, base64url without padding. Create it once, out of band, in the secret
# manager; the service reads it only from a 0600 file, never from the environment.
kubectl -n authority-system create secret generic authority-policy-key \
  --from-file=policy.key=./policy.key
kubectl -n authority-system create secret generic authority-tls \
  --from-file=tls.crt --from-file=tls.key --from-file=ca.crt
kubectl -n authority-system create configmap authority-policy \
  --from-file=policy.json --from-file=approvers.json
```

`ca.crt` is the CA that issues the client certificates of the actuator and the control
plane; the listener enforces TLS 1.3 with `verify_peer` and `fail_if_no_peer_cert`.
`policy.json` and `approvers.json` are public data (policy tiers, approver registry).

## Key file mode

`AuthorityService.KeyFile.load/1` refuses a key file with any group/world permission bit.
Kubernetes adds group read to Secret volumes when `fsGroup` is set, so the `install-key`
init container copies the key with mode 0600 into an in-memory `emptyDir` that only the
service mounts. The image must therefore provide `/bin/sh` and `install`.

## Image digest pin

`kustomization.yaml` carries an all-zero digest placeholder on purpose so an unbuilt image
can never be deployed. Replace it with the real digest of the release image built from
`authority_service/` (`kustomize edit set image ...`). Tags are never deployed.

## Isolation facts

- `RELEASE_DISTRIBUTION=none` (env and release `rel/env.sh.eex`), `-start_epmd false` in
  `rel/vm.args.eex`: no dist port, no epmd, no cookie RPC surface. Ports 4369/9000 are not
  declared and not allowed by the NetworkPolicy.
- No egress at all. When the sa2a-approver channel is wired, add an explicit egress policy
  for that destination in an overlay.
- Single replica: the issuance journal (`/var/lib/authority/journal.log`) is a single-writer
  hash-chained file on a PVC.

## See Also

- `authority_service/lib/authority_service/listener.ex` (wire), `issuer.ex` (refusal codes)
- `k8s/README.md`, `k8s/network-policy.yaml` (conventions reused)
- `docs/rfc/RFC-SA2A-006-*` s7.4 / s13
