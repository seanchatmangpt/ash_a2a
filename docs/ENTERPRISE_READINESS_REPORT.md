# Distributed-agent swarm: security & resilience readiness

Real evidence gathered 2026-09-15 against a real `kind` cluster
(`ash-a2a-swarm`, Kubernetes v1.34.0), a real 3-replica `ash_a2a` A2A-agent
Deployment (`k8s/deployment.yaml`, image `ash-a2a-swarm-node:local`
`sha256:24c1356d…`, built from `swarm/Dockerfile` at ash_a2a commit
`951c554d4eb5451b6de324df0fe62f08d84cfac5`), and the real security-scan
tooling a regulated/enterprise buyer's own review team would run
(kubeconform, Trivy, Kyverno, Kubescape — the same orthogonal-scanner
layer `~/ggen-marketplace/packs/kubernetes-workload-pack` already
established as this ecosystem's standard).

**What this report is, and is not.** This is evidence a security/procurement
review can act on today, not a certification and not a claim about any
specific customer, deal, or dollar figure — none of that is in scope here
or known to this session. It answers two concrete questions a
Fortune-5-class regulated buyer's review typically gates on before a deal
can even be evaluated: *"can this run as a real distributed system, and
can you prove its Kubernetes posture and failure behavior are sound?"*
Everything below is either a command you can re-run, or a real output
already captured. See `~/ggen-marketplace/packs/kubernetes-workload-pack/
examples/control-mapping/control-map.md` for this ecosystem's own
assessment-boundary vocabulary (`WORKLOAD_CONTROL` / `NAMESPACE_CONTROL` /
`CLUSTER_CONTROL` / `INHERITED`), reused here rather than reinvented.

## 1. Real distributed-agent dispatch (not simulated)

Reference: `k8s/README.md`, `swarm/lib/swarm_node/probe.ex`.

3 pods, each a real `AshA2A.Agent` GenServer (`SwarmNode.EchoAgent`),
joined a real distributed-Erlang cluster via `libcluster`'s
`Cluster.Strategy.Kubernetes.DNS` strategy against a real headless
Service (`k8s/headless-service.yaml`). From pod `10.244.0.5`, dispatching
the real A2A skill against both real peers and reading back each peer's
own `Kernel.node/0` value (not a caller-supplied one):

```json
{"dispatches":[
  {"status":"ok","peer":"swarm_node@10.244.0.7","reply_node":"swarm_node@10.244.0.7","task_state":"completed"},
  {"status":"ok","peer":"swarm_node@10.244.0.6","reply_node":"swarm_node@10.244.0.6","task_state":"completed"}],
 "peers_seen":["swarm_node@10.244.0.7","swarm_node@10.244.0.6"],
 "self_node":"swarm_node@10.244.0.5",
 "swarm_dispatch_verified":true}
```

**Standing: ALIVE.** Reproduce: `bash k8s/deploy.sh`.

## 2. Real resilience under real pod failure

A regulated buyer's SRE/ops review asks "what happens when a node dies,"
not just "does it work once." Real test performed against the running
cluster above: `kubectl delete pod ash-a2a-swarm-...-pw8dn` (the pod that
had just replied to the dispatch above, at `10.244.0.7`).

| Step | Real result |
|---|---|
| Kubernetes Deployment controller reschedules the killed pod | New pod `ash-a2a-swarm-...-6p26k` (`10.244.0.8`) `1/1 Running` within seconds — `kubectl rollout status` reported success, no manual intervention |
| Surviving node (`10.244.0.5`) drops the dead peer | Confirmed via `Node.list()`: `[:"swarm_node@10.244.0.6"]` immediately after, `swarm_node@10.244.0.7` gone |
| Surviving node auto-discovers and connects the *new* pod | `libcluster`'s continuous 5s DNS-poll reconnected within ~8s, no restart/redeploy of the survivor needed |
| Full swarm dispatch re-verified post-chaos | `{"dispatches":[{"peer":"swarm_node@10.244.0.6","reply_node":"swarm_node@10.244.0.6",...},{"peer":"swarm_node@10.244.0.8","reply_node":"swarm_node@10.244.0.8",...}],"swarm_dispatch_verified":true}` |

**Standing: ALIVE.** Reproduce: `bash k8s/deploy.sh` (now runs this chaos
step automatically as part of the deploy/verify flow).

## 3. Kubernetes security posture (NIST/CIS/NSA-mapped)

Field values copied directly from `kubernetes-workload-pack`'s real,
cited `high-assurance-workload` example (NIST SP 800-53 Rev.5, NIST SP
800-190, CIS Kubernetes Benchmark, CISA/NSA Kubernetes Hardening
Guidance — see that pack's `control-map.md` for full citations, not
reproduced here to avoid two documents drifting apart):

| Control | This deployment | Standing |
|---|---|---|
| Non-root execution, explicit UID/GID/fsGroup | `runAsNonRoot: true`, uid/gid/fsGroup 10001 | ALIVE |
| Seccomp `RuntimeDefault` | set at pod level | ALIVE |
| No privilege escalation, all capabilities dropped | `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` | ALIVE |
| Read-only root filesystem | `readOnlyRootFilesystem: true` (writable `/tmp` via `emptyDir` for the release's own runtime tmp only) | ALIVE |
| Explicit CPU/memory requests + limits | 250m/256Mi requests, 1/512Mi limits per container | ALIVE |
| Namespace `ResourceQuota` enforcing the aggregate boundary | `requests.cpu: "3"`, `requests.memory: 3Gi` | ALIVE |
| Dedicated ServiceAccount, no default-SA reliance | `ash-a2a-swarm` SA | ALIVE |
| No ambient API-server token | `automountServiceAccountToken: false` — this workload needs **zero** RBAC (libcluster's DNS strategy never calls the Kubernetes API) | ALIVE |
| Pod Security Admission `restricted` | Namespace labeled `pod-security.kubernetes.io/enforce=restricted` | ALIVE |
| Default-deny NetworkPolicy + explicit allow | `k8s/network-policy.yaml` (deny-all + allow only pod-to-pod on the real distribution ports + DNS egress) | **ALIVE — see correction below** |
| Immutable, digest-pinned image | `ash-a2a-swarm-node:local`, a `kind`-loaded local tag, never pushed to a registry | **BLOCKED for this local run, not this deployment's design** — see caveat below |

### Correction (re-derived from a real falsifier, not assumed)

An earlier draft of this report claimed `kind`'s default CNI (`kindnet`)
does not enforce `NetworkPolicy`, reasoning from `kindnet-czq6s` being the
only CNI pod in `kube-system` with (it was assumed) no policy-engine
component. That assumption was **wrong** and has been corrected after a
real, direct test (see `docs/AIRGAP_READINESS_REPORT.md` test 1 for the
full real command/output): with `k8s/network-policy.yaml` removed, a raw
`:gen_tcp.connect/4` from inside a pod to a public IP succeeds
(`{:ok, _}`); with the same policy re-applied, the identical call times
out (`{:error, :timeout}`). This kind version (`kindnet` bundled with
kind v0.30.0 / Kubernetes v1.34.0) does enforce `NetworkPolicy` for real
egress traffic. Real intra-cluster dispatch and internal DNS resolution
were reconfirmed still working with the policy applied. The one real,
narrower residual gap this correction surfaced — CoreDNS's own default
forwarder still resolves external hostnames despite the IP-level egress
block — is disclosed in full in `docs/AIRGAP_READINESS_REPORT.md`, not
here, to avoid the two documents drifting apart.

### Caveat, stated honestly rather than rounded up

- **Image digest pinning** (the other row above) is the remaining real
  gap (SEC-IMG-001): this session never pushed the image to a registry — it was built and `kind load
  docker-image`'d locally only, so there is no real registry digest to
  pin to. A real release pipeline (build → push to a registry → deploy by
  `@sha256:` digest, optionally Sigstore/cosign-signed) closes this; that
  pipeline does not exist yet for this app and is correctly not
  fabricated here.

### Real, independent scanner results (this session, this exact manifest set)

| Tool | Result |
|---|---|
| `kubeconform -strict -summary` | 7 resources across 6 files: 7 valid, 0 invalid, 0 errors |
| `trivy config --severity HIGH,CRITICAL` | 0 misconfigurations across all 6 files |
| `kyverno apply` (kubernetes-workload-pack's own `restricted-pss-subset.kyverno.yaml`) | 3 pass / 1 fail — the 1 failure is the known, disclosed local-image-digest gap above, not a posture defect |
| `kubescape scan framework NSA` (deployment + NetworkPolicy) | 20/20 controls pass, 100% compliance |

## 4. Explicitly out of scope / not claimed

- **No claim about any specific customer, deal, or revenue figure.**
  This report closes a real capability gap (can this run distributed,
  is its k8s posture sound, does it survive a real pod failure) that a
  revenue-relevant motion (enterprise sales review, a pro/hosted tier,
  an investor/design-partner conversation) would need — it is not itself
  a revenue event, and none of those specific conversations are in this
  session's context.
- RBAC beyond the dedicated ServiceAccount, HorizontalPodAutoscaler,
  PodDisruptionBudget, image signing/provenance, SBOM — same
  `NAMESPACE_CONTROL`/`SUPPLY_CHAIN_CONTROL` boundary
  `kubernetes-workload-pack`'s own control-map.md already documents as
  disclosed backlog, not silently assumed done.
- Multi-*node* kind topology (this test used `kind`'s single-node
  control-plane container hosting all 3 pods) — real pod-level failure
  and real distributed-Erlang behavior are proven; real separate-VM/
  separate-physical-node failure is not (that gap already exists and is
  tracked in `docs/jira/v26.9.14/ERRC_TRACKER.md`'s "DurableServer
  cross-node rehome" item, which this swarm test's `SwarmNode.Echo`
  payload does not yet exercise — a real, valuable follow-on).

## Reproduce this report

```
bash k8s/deploy.sh          # full deploy + probe + chaos test, real output on stdout/stderr
kubeconform -strict -summary k8s/*.yaml
trivy config --severity HIGH,CRITICAL k8s/
kyverno apply ~/ggen-marketplace/packs/kubernetes-workload-pack/qualification/policies/restricted-pss-subset.kyverno.yaml --resource k8s/deployment.yaml
kubescape scan framework NSA k8s/deployment.yaml k8s/network-policy.yaml
kind delete cluster --name ash-a2a-swarm   # cleanup
```
