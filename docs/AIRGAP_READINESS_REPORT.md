# Disconnected / air-gapped operational readiness test

**Naming discipline, stated up front**: this is an *operational readiness
test*, not a Top Secret or any other formal classification/ATO
determination — that status can only be granted by a real accrediting
authority through a real assessment process, and nothing in this session
performs or claims one. What follows is real evidence an assessor would
want to see, not a certification.

Real evidence gathered 2026-09-15 against the same running `kind` cluster
(`ash-a2a-swarm`) and Deployment as `docs/ENTERPRISE_READINESS_REPORT.md`,
extended with three additional real constraints and a falsifier for each
— **zero outbound connectivity**: no internet, no external registry, no
external LLM API, no external DNS resolution of anything but this
cluster's own names.

## What it proves, mapped to real controls

| # | Control | Test | Real result |
|---|---|---|---|
| 1 | NIST SP 800-53 SC-7(5), deny-by-default egress | From inside a running pod, real raw TCP connect to a public IP (`8.8.8.8:443` — an IP, not a hostname, so DNS isn't what's being tested) | **Positive control** (NetworkPolicy removed): `{:ok, #Port<0.61>}` — connects. **With `k8s/network-policy.yaml` applied**: `{:error, :timeout}` — blocked. Real falsifier passed: this isn't "we wrote a NetworkPolicy," it's confirmed the same exact call actually changes outcome when the policy is present vs absent. |
| 2 | NIST SP 800-53 SA-9, external system services (offline image provenance) | `imagePullPolicy: Never` (not `IfNotPresent`, which can still silently reach for a registry on a cache miss) applied to `k8s/deployment.yaml`; full re-rollout | All 3 pods scheduled and reached `1/1 Running` under the new ReplicaSet with zero registry access — confirmed via `kubectl rollout status` success and `kubectl get pods` showing `Running`, not `ErrImageNeverPull`. |
| 3 | NIST SP 800-53 CM-7, least functionality (internal-only DNS) | Real `:inet_res.lookup/3` calls from inside a pod, via `rpc`, for (a) this cluster's own headless Service name and (b) a real external hostname | (a) **Internal name resolves correctly**: `ash-a2a-swarm-headless.ash-a2a-swarm.svc.cluster.local` → the 3 real pod IPs. (b) **Real, disclosed residual gap, not glossed over**: `www.google.com` also resolved (to a real public IP) *despite* the egress block in test 1 — see caveat below. |
| 4 | Core agent-to-agent dispatch capability, re-verified under all 3 constraints simultaneously | Re-ran the exact `SwarmNode.Probe.run()` call already proven in `ENTERPRISE_READINESS_REPORT.md`, with the NetworkPolicy, `imagePullPolicy: Never`, and the DNS findings above all in place at once | `{"dispatches":[{"peer":"swarm_node@10.244.0.9","reply_node":"swarm_node@10.244.0.9",...},{"peer":"swarm_node@10.244.0.11","reply_node":"swarm_node@10.244.0.11",...}],"swarm_dispatch_verified":true}` — the real agent-to-agent capability needs nothing external. |

## Real, disclosed residual gap: DNS-forwarder egress (test 3b)

`kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'`
shows this cluster's default CoreDNS config includes `forward .
/etc/resolv.conf` — CoreDNS itself (a `kube-system` workload, entirely
outside this app's own namespace and NetworkPolicy) forwards any
non-`cluster.local` query to the node's upstream resolver. Because
`NetworkPolicy` operates on IP/port, not DNS query content, my namespace's
"allow port 53 to kube-dns" rule (needed for real internal service
discovery, per `ENTERPRISE_READINESS_REPORT.md`) cannot distinguish an
internal-name query from an external one once it reaches CoreDNS —
CoreDNS resolves *both*, and the resolution for an external name
succeeds using CoreDNS's *own* egress, not this workload's.

**Practical consequence**: direct TCP/IP exfiltration is blocked (test
1); a DNS-query-based channel is not, by default, on this cluster.
**Standing: real, PARTIAL_ALIVE, not full** — this is a `CLUSTER_CONTROL`-
layer configuration (the CoreDNS `Corefile` itself, and/or a
`kube-system`-scoped `NetworkPolicy` restricting CoreDNS's own egress),
outside what this app's namespace-scoped manifests can set — the same
assessment boundary `kubernetes-workload-pack`'s own control-map.md
already uses for the target enclave's PKI/NTP/registry-mirror
configuration. A real air-gapped enclave's own platform team owns closing
this (removing or redirecting the `forward` clause, or a `kube-system`
egress policy) — it is not fixable from this app's own `k8s/` manifests,
and this session does not fabricate having closed it.

## Honest carve-out: the semantic/LLM planning surface is NOT air-gap-ready

`lib/ash_a2a/semantic/compiler.ex` and
`lib/ash_a2a/planning/semantic_synthesis.ex` call `ReqLLM.generate_object/4`
against a real, configured live model provider (see `AshA2A.LLMProfiles`)
— this is a real, live network dependency this swarm test's
`SwarmNode.EchoAgent` payload never exercises (it has no semantic-request
skill wired in), so the results above say nothing about that surface.
**Any report combining this document with the core agent-dispatch result
must state this explicitly** — claiming the whole system is air-gap-ready
based on this test alone would overclaim. Making the semantic/planning
surface air-gap-capable needs a real local model server story (e.g. a
locally-hosted OpenAI-API-compatible endpoint reachable only inside the
enclave's own network) — a real, separate, unbuilt piece of work, not
attempted here.

## Standing summary (same vocabulary as `ENTERPRISE_READINESS_REPORT.md`)

- **ALIVE**: egress deny-by-default (test 1, real positive+negative
  control), offline image provenance (test 2), internal-name DNS
  resolution (test 3a), core agent-dispatch capability under all
  constraints (test 4).
- **PARTIAL_ALIVE**: least-functionality/DNS (test 3b) — internal
  resolution correct, external-name resolution via CoreDNS's own
  forwarder not blocked by this app's own manifests.
- **INHERITED** (this enclave's own platform team, not this app):
  CoreDNS forwarder reconfiguration, the target enclave's own PKI/NTP/
  internal registry mirror — no test on this machine can stand in for
  those.
- **OUT-OF-SCOPE, disclosed**: the LLM-backed semantic/planning surface.
  Not air-gap-ready today; needs a local-model-server story that does
  not yet exist.

## Reproduce

```
# 1. Egress falsifier (positive control, then negative control)
kubectl -n ash-a2a-swarm delete -f k8s/network-policy.yaml
kubectl -n ash-a2a-swarm exec <pod> -- /app/bin/swarm_node rpc \
  'IO.inspect(:gen_tcp.connect(~c"8.8.8.8", 443, [], 5000))'   # expect {:ok, _}
kubectl apply -f k8s/network-policy.yaml
kubectl -n ash-a2a-swarm exec <pod> -- /app/bin/swarm_node rpc \
  'IO.inspect(:gen_tcp.connect(~c"8.8.8.8", 443, [], 5000))'   # expect {:error, :timeout}

# 2. Offline image provenance -- k8s/deployment.yaml already sets
#    imagePullPolicy: Never; just re-apply and watch it schedule
kubectl apply -f k8s/deployment.yaml
kubectl -n ash-a2a-swarm rollout status deployment/ash-a2a-swarm --timeout=90s

# 3. DNS scope
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
kubectl -n ash-a2a-swarm exec <pod> -- /app/bin/swarm_node rpc \
  'IO.inspect(:inet_res.lookup(~c"www.google.com", :in, :a))'

# 4. Core dispatch, all constraints active
kubectl -n ash-a2a-swarm exec <pod> -- /app/bin/swarm_node rpc 'SwarmNode.Probe.run()'
```
