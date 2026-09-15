# SSP Control Implementation Appendix

**Last Updated: 2026-09-15**

> **This is an internal evidence appendix. It is NOT an Authority to
> Operate (ATO), NOT a certification of any kind, NOT a FedRAMP/NIST/CIS
> accreditation, and NOT a system-categorization or classification
> determination.** No accrediting authority, assessor, or Authorizing
> Official has reviewed or issued any status here. This document confers
> **no** compliance, certification, or operational-authorization status
> on `ash_a2a` or on any deployment of it. It exists to organize
> already-gathered, already-real evidence into a NIST-SP-800-18-shaped
> control-implementation format so a real future assessor has a
> starting index — nothing more.

## 1. Purpose and provenance

[NIST Special Publication 800-18 Revision 1, *Guide for Developing
Security Plans for Federal Information Systems*](https://csrc.nist.gov/pubs/sp/800/18/r1/final)
(Feb 2006) specifies that a System Security Plan's control-implementation
section state, per control: the control identifier and name, its
implementation status, and a description of how it is (or is not)
implemented. This appendix follows that per-control statement shape —
**and only that shape**. It does not attempt the rest of a full SSP
(system categorization, rules of behavior, contingency plan, interconnection
agreements, Authorizing Official sign-off) because none of that exists or
has been performed in this session; inventing those sections would
overclaim status this document explicitly disclaims above.

Every entry below is built **only** from real evidence already recorded in:

- `docs/ENTERPRISE_READINESS_REPORT.md` — real `kind`-cluster distributed
  dispatch, pod-failure resilience, and Kubernetes security-posture
  evidence, gathered 2026-09-15.
- `docs/AIRGAP_READINESS_REPORT.md` — real disconnected/air-gapped
  operational-readiness evidence against the same cluster, gathered
  2026-09-15.

No new test was run, and no finding not already present in one of those
two documents was added, to produce this appendix. Where those two
documents already state an explicit NIST SP 800-53 control identifier
(the air-gap report's SC-7(5), SA-9, CM-7), that identifier is reused
verbatim below. Where the enterprise report cites a control-*family* set
in aggregate (NIST SP 800-53 Rev.5 / NIST SP 800-190 / CIS Kubernetes
Benchmark / CISA-NSA Kubernetes Hardening Guidance) without a per-row
identifier, this appendix preserves that aggregate citation rather than
inventing a specific control number — the per-control ID-to-field mapping
for that framework set lives in
`~/ggen-marketplace/packs/kubernetes-workload-pack/examples/control-mapping/control-map.md`,
which documents the *pack's own example fixtures*, not this app's real
deployment; conflating the two would misattribute evidence, so this
appendix cites that file only for its shared assessment-boundary
vocabulary (`WORKLOAD_CONTROL` / `NAMESPACE_CONTROL` / `CLUSTER_CONTROL` /
`SUPPLY_CHAIN_CONTROL` / `INHERITED`), reused here rather than reinvented,
and never for a per-row NIST ID this app's own reports do not themselves
state.

## 2. System identification (minimal, honest)

| Field | Value |
|---|---|
| System name | `ash_a2a` distributed-agent swarm — `kind`-cluster test deployment (`ash-a2a-swarm` namespace) |
| System description | 3-replica `AshA2A.Agent` GenServer swarm (`SwarmNode.EchoAgent`) on real Kubernetes, joined via `libcluster`'s `Cluster.Strategy.Kubernetes.DNS` (`docs/ENTERPRISE_READINESS_REPORT.md` §1) |
| Environment tested | Local `kind` v0.30.0, Kubernetes v1.34.0, single-node control-plane container hosting all 3 pods |
| System owner / Authorizing Official / FIPS 199 categorization / responsible organization | **Not established in this session.** These are organizational/ISSO/AO determinations outside the scope of an evidence-gathering session and are correctly left blank rather than fabricated. |
| Control origination / responsible role per control | **Intentionally omitted.** Assigning organizational responsibility per control is a FedRAMP-SSP-template addition beyond NIST SP 800-18's base guide and beyond what this evidence-gathering session performed or can honestly assert. |

## 3. Control implementation statements — NIST SP 800-53-identified controls

These three entries carry an explicit NIST SP 800-53 Rev.5 control
identifier because `docs/AIRGAP_READINESS_REPORT.md`'s own evidence table
states it directly (not re-derived here).

### SC-7(5) — Boundary Protection | Deny by Default, Allow by Exception

- **Implementation status: Implemented.**
- **Control implementation statement**: The namespace's default-deny
  `NetworkPolicy` (`k8s/network-policy.yaml`) blocks all egress except an
  explicit allow for pod-to-pod traffic on the real distribution ports and
  DNS egress. This was verified with a real positive/negative falsifier,
  not assumed from the manifest's existence: from inside a running pod, a
  raw `:gen_tcp.connect(~c"8.8.8.8", 443, ...)` to a public IP succeeds
  (`{:ok, _}`) with the policy removed, and times out (`{:error, :timeout}`)
  with the identical policy re-applied. Real intra-cluster dispatch and
  internal DNS resolution were reconfirmed still working with the policy
  applied.
- **Evidence**: `docs/AIRGAP_READINESS_REPORT.md` table row 1 (real
  command + result); cross-referenced from
  `docs/ENTERPRISE_READINESS_REPORT.md` §3's "Correction (re-derived from
  a real falsifier, not assumed)" subsection, which also documents the
  earlier, wrong assumption (that `kind`'s CNI does not enforce
  `NetworkPolicy`) and its correction.
- **Known residual gap** (same control area, disclosed, not rounded up):
  see CM-7 below — the block is IP/port-level; a DNS-query-based channel
  through CoreDNS's own forwarder is not closed by this app's manifests.

### SA-9 — External System Services (offline image provenance)

- **Implementation status: Implemented**, for the constraint actually
  tested (zero registry access at pod-schedule time in this cluster).
- **Control implementation statement**: `k8s/deployment.yaml` sets
  `imagePullPolicy: Never` (deliberately not `IfNotPresent`, which can
  still silently reach for a registry on a cache miss). A full re-rollout
  under this setting scheduled and reached all 3 pods `1/1 Running` on a
  new ReplicaSet with zero registry access, confirmed via `kubectl
  rollout status` success and `kubectl get pods` showing `Running`, not
  `ErrImageNeverPull`.
- **Evidence**: `docs/AIRGAP_READINESS_REPORT.md` table row 2; reproduce
  commands under "Reproduce" item 2 in that same document.
- **Related, disclosed gap** (not this control, see §5 below):
  image-digest pinning to an external registry is a separate,
  **Planned**, not-yet-implemented item (SEC-IMG-001-class gap) — this
  session never pushed the image to any registry, so there is no real
  registry digest to pin to.

### CM-7 — Least Functionality (internal-only DNS resolution)

- **Implementation status: Partially Implemented.**
- **Control implementation statement**: Real `:inet_res.lookup/3` calls
  from inside a pod, via `rpc`, confirm (a) this cluster's own headless
  Service name resolves correctly to the 3 real pod IPs
  (`ash-a2a-swarm-headless.ash-a2a-swarm.svc.cluster.local`), which is the
  intended, minimal internal-DNS functionality. However, (b) the same
  pod's lookup of a real external hostname (`www.google.com`) **also**
  resolves, to a real public IP, despite the SC-7(5) egress block above —
  this is a real, disclosed residual gap, not glossed over.
- **Root cause, disclosed**: `kubectl -n kube-system get configmap coredns
  -o jsonpath='{.data.Corefile}'` shows the cluster's default CoreDNS
  config includes `forward . /etc/resolv.conf`. CoreDNS (a `kube-system`
  workload, outside this app's own namespace and `NetworkPolicy`)
  forwards any non-`cluster.local` query to the node's upstream resolver.
  Because `NetworkPolicy` operates on IP/port and not DNS query content,
  this app's "allow port 53 to kube-dns" rule (itself needed for real
  internal service discovery) cannot distinguish an internal-name query
  from an external one once it reaches CoreDNS.
- **Practical consequence, as stated in source**: direct TCP/IP
  exfiltration is blocked (SC-7(5) above); a DNS-query-based channel is
  not, by default, on this cluster.
- **Evidence**: `docs/AIRGAP_READINESS_REPORT.md` table row 3 and the
  "Real, disclosed residual gap: DNS-forwarder egress (test 3b)" section
  in full.
- **Disposition**: this is a `CLUSTER_CONTROL`-layer configuration item
  (the CoreDNS `Corefile` itself, and/or a `kube-system`-scoped
  `NetworkPolicy` restricting CoreDNS's own egress) outside what this
  app's namespace-scoped manifests can set. See §6 (Inherited) below.

## 4. Control implementation statements — container/pod hardening posture

**Framework citation, applied to every entry in this section as a set**
(per `docs/ENTERPRISE_READINESS_REPORT.md` §3's own header sentence, not
re-derived here): NIST SP 800-53 Rev.5, NIST SP 800-190 (Application
Container Security Guide), CIS Kubernetes Benchmark, CISA/NSA Kubernetes
Hardening Guidance. Per-row NIST SP 800-53 control identifiers for this
framework set are documented for the pack's own reference fixture at
`~/ggen-marketplace/packs/kubernetes-workload-pack/examples/control-mapping/control-map.md`;
this appendix does not restate those specific IDs against this app's real
deployment, since that per-ID mapping was verified against the pack's own
example workload, not against `k8s/deployment.yaml` — restating it here
would misattribute the pack's evidence as this app's own.

| Control area | Implementation status | Control implementation statement | Evidence |
|---|---|---|---|
| Non-root execution, explicit UID/GID/fsGroup | Implemented | `runAsNonRoot: true`; UID/GID/fsGroup `10001` set at pod security-context level | `k8s/deployment.yaml`; ENTERPRISE report §3 table row 1 |
| Seccomp profile `RuntimeDefault` | Implemented | Set at pod level (never `Unconfined`) | `k8s/deployment.yaml`; ENTERPRISE report §3 table row 2 |
| No privilege escalation; all Linux capabilities dropped | Implemented | `allowPrivilegeEscalation: false`; `capabilities.drop: ["ALL"]` | `k8s/deployment.yaml`; ENTERPRISE report §3 table row 3 |
| Read-only root filesystem | Implemented | `readOnlyRootFilesystem: true`, with a scoped `emptyDir`-backed `/tmp` for the release's own runtime tmp only | `k8s/deployment.yaml`; ENTERPRISE report §3 table row 4 |
| Explicit CPU/memory requests and limits | Implemented | `250m`/`256Mi` requests, `1`/`512Mi` limits per container | `k8s/deployment.yaml`; ENTERPRISE report §3 table row 5 |
| Namespace `ResourceQuota` (aggregate boundary) | Implemented | `requests.cpu: "3"`, `requests.memory: 3Gi` enforced at namespace scope | ENTERPRISE report §3 table row 6 |
| Dedicated ServiceAccount, no default-SA reliance | Implemented | `ash-a2a-swarm` ServiceAccount, not the namespace default | ENTERPRISE report §3 table row 7 |
| No ambient API-server token | Implemented | `automountServiceAccountToken: false` — this workload needs zero RBAC, since `libcluster`'s DNS strategy never calls the Kubernetes API | ENTERPRISE report §3 table row 8 |
| Pod Security Admission `restricted` | Implemented | Namespace labeled `pod-security.kubernetes.io/enforce=restricted` | ENTERPRISE report §3 table row 9 |
| Default-deny `NetworkPolicy` + explicit allow | Implemented (corrected finding — see SC-7(5) above) | `k8s/network-policy.yaml`: deny-all plus explicit allow for pod-to-pod on the real distribution ports and DNS egress | ENTERPRISE report §3 table row 10 + "Correction" subsection; AIRGAP report table row 1 |
| Immutable, digest-pinned image | **Planned** | `ash-a2a-swarm-node:local` is a `kind`-loaded local tag, never pushed to any registry — there is no real registry digest to pin to yet. A real release pipeline (build → push to a registry → deploy by `@sha256:` digest, optionally Sigstore/cosign-signed) would close this; that pipeline does not exist for this app today and is correctly not fabricated here. | ENTERPRISE report §3 table row 11 + "Caveat, stated honestly rather than rounded up" subsection (`SEC-IMG-001`) |

### Independent verification tooling (real, this exact manifest set)

These scanner runs are cited as the verification evidence backing the
"Implemented" rows above — they are independent of this app's own claims
about itself.

| Tool | Real result | Backs |
|---|---|---|
| `kubeconform -strict -summary` | 7 resources across 6 files: 7 valid, 0 invalid, 0 errors | All rows above (schema conformance) |
| `trivy config --severity HIGH,CRITICAL` | 0 misconfigurations across all 6 files | All rows above (static misconfiguration) |
| `kyverno apply` (`kubernetes-workload-pack`'s `restricted-pss-subset.kyverno.yaml`) | 3 pass / 1 fail — the 1 failure is the disclosed image-digest gap above, not a posture defect | Non-root/seccomp/no-priv-esc/cap-drop rows; confirms image-digest row's Planned status |
| `kubescape scan framework NSA` (Deployment + NetworkPolicy) | 20/20 controls pass, 100% compliance | All rows above |

## 5. Explicitly Not Implemented / Planned / Out of Scope (disclosed backlog)

Carried forward verbatim from each source report's own disclosure
sections — nothing new added here.

| Item | Status | Source |
|---|---|---|
| RBAC beyond the dedicated ServiceAccount | Not Implemented (disclosed backlog) | ENTERPRISE report §4 |
| `HorizontalPodAutoscaler` | Not Implemented | ENTERPRISE report §4 |
| `PodDisruptionBudget` | Not Implemented | ENTERPRISE report §4 |
| Image signing/provenance, SBOM | Not Implemented | ENTERPRISE report §4 |
| Multi-*node* (separate VM/physical-node) failure behavior | Not Tested — only single-node `kind` pod-level failure is proven; tracked in `docs/jira/v26.9.14/ERRC_TRACKER.md`'s "DurableServer cross-node rehome" item | ENTERPRISE report §4 |
| Image digest pinning (production release pipeline) | Planned (see §4 table, `SEC-IMG-001`) | ENTERPRISE report §3 |
| CoreDNS forwarder / DNS-based egress channel | Partially Implemented (see CM-7 above) | AIRGAP report, "Real, disclosed residual gap" section |
| LLM-backed semantic/planning surface (`lib/ash_a2a/semantic/compiler.ex`, `lib/ash_a2a/planning/semantic_synthesis.ex`) air-gap readiness | **Not Implemented / Out of Scope.** These call `ReqLLM.generate_object/4` against a real, live, configured model provider (`AshA2A.LLMProfiles`) — a real live network dependency this swarm test's `SwarmNode.EchoAgent` payload never exercises. Any report combining this appendix with the core agent-dispatch result must state this explicitly; treating the whole system as air-gap-ready on this evidence alone would overclaim. Closing this needs a real local-model-server story (e.g. a locally-hosted OpenAI-API-compatible endpoint reachable only inside the enclave's own network) — separate, unbuilt work, not attempted here. | AIRGAP report, "Honest carve-out" section |
| Cosign/image-signature verification | Not Implemented | ENTERPRISE report §4 (same `SUPPLY_CHAIN_CONTROL` boundary as image-digest pinning) |

## 6. Inherited (platform-owned, not this app's manifests)

Per `docs/AIRGAP_READINESS_REPORT.md`'s own "Standing summary":

- **CoreDNS forwarder reconfiguration** — removing or redirecting the
  `forward` clause in the cluster's `Corefile`, or a `kube-system`-scoped
  egress `NetworkPolicy`, is this enclave's own platform team's
  responsibility; it is not fixable from this app's own `k8s/` manifests.
- **Target enclave's own PKI/NTP/internal registry mirror** — no test on
  this machine can stand in for those; this is the same
  `CLUSTER_CONTROL`/platform-operator assessment boundary
  `kubernetes-workload-pack`'s own `control-map.md` documents for the
  general pattern (Pod Security Admission enforcement mode, CNI policy
  enforcement, node-level configuration) — cited here only for shared
  vocabulary, not as evidence about this app.

## 7. Supporting operational-capability evidence

These findings are real and already gathered, but the source reports do
not tag them with a specific NIST SP 800-53 control identifier — they are
recorded here as capability evidence that the controls above operate
inside a real, working distributed system, not as separate NIST-ID rows.

- **Real distributed-agent dispatch** (not simulated): 3 pods, each a
  real `AshA2A.Agent` GenServer, joined a real distributed-Erlang cluster
  and dispatched a real A2A skill against real peers, reading back each
  peer's own `Kernel.node/0` value. Standing: ALIVE. Source: ENTERPRISE
  report §1 (`k8s/README.md`, `swarm/lib/swarm_node/probe.ex`).
- **Real resilience under real pod failure**: a running pod was deleted
  (`kubectl delete pod ...`); the Deployment controller rescheduled it
  within seconds with no manual intervention; the surviving node dropped
  the dead peer and auto-discovered the new one via `libcluster`'s 5s
  DNS-poll within ~8s; full swarm dispatch was re-verified post-chaos.
  Standing: ALIVE. Source: ENTERPRISE report §2.
- **Core agent-to-agent dispatch re-verified under all air-gap
  constraints simultaneously** (`NetworkPolicy` + `imagePullPolicy: Never`
  + the DNS findings above, all in place at once): dispatch succeeded,
  confirming the real agent-to-agent capability needs nothing external.
  Standing: ALIVE. Source: AIRGAP report table row 4.

## 8. Evidence index / reproduction commands

Reproduced verbatim from each source document's own "Reproduce" section
— re-run these to regenerate the underlying evidence independently of
this appendix.

```
# From docs/ENTERPRISE_READINESS_REPORT.md
bash k8s/deploy.sh          # full deploy + probe + chaos test, real output on stdout/stderr
kubeconform -strict -summary k8s/*.yaml
trivy config --severity HIGH,CRITICAL k8s/
kyverno apply ~/ggen-marketplace/packs/kubernetes-workload-pack/qualification/policies/restricted-pss-subset.kyverno.yaml --resource k8s/deployment.yaml
kubescape scan framework NSA k8s/deployment.yaml k8s/network-policy.yaml
kind delete cluster --name ash-a2a-swarm   # cleanup

# From docs/AIRGAP_READINESS_REPORT.md
kubectl -n ash-a2a-swarm delete -f k8s/network-policy.yaml
kubectl -n ash-a2a-swarm exec <pod> -- /app/bin/swarm_node rpc \
  'IO.inspect(:gen_tcp.connect(~c"8.8.8.8", 443, [], 5000))'   # expect {:ok, _}
kubectl apply -f k8s/network-policy.yaml
kubectl -n ash-a2a-swarm exec <pod> -- /app/bin/swarm_node rpc \
  'IO.inspect(:gen_tcp.connect(~c"8.8.8.8", 443, [], 5000))'   # expect {:error, :timeout}

kubectl apply -f k8s/deployment.yaml
kubectl -n ash-a2a-swarm rollout status deployment/ash-a2a-swarm --timeout=90s

kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
kubectl -n ash-a2a-swarm exec <pod> -- /app/bin/swarm_node rpc \
  'IO.inspect(:inet_res.lookup(~c"www.google.com", :in, :a))'

kubectl -n ash-a2a-swarm exec <pod> -- /app/bin/swarm_node rpc 'SwarmNode.Probe.run()'
```

## 9. Scope closure note

This appendix organizes real, already-gathered evidence into a
NIST-SP-800-18-shaped per-control format. It does **not** perform, and
cannot substitute for, a real security categorization, a real NIST SP
800-53A control assessment by an independent assessor, or a real
Authorizing Official's risk-acceptance decision. Any of those remains a
real, separate, unbuilt piece of work — this document closes the "can we
show our evidence in the shape an assessor expects" question, not the
"are we authorized to operate" question, and does not claim otherwise.

## See Also

- `docs/ENTERPRISE_READINESS_REPORT.md` — primary evidence source (§§1-4)
- `docs/AIRGAP_READINESS_REPORT.md` — primary evidence source (all sections)
- `~/ggen-marketplace/packs/kubernetes-workload-pack/examples/control-mapping/control-map.md` — shared assessment-boundary vocabulary, cited for terminology only
- [NIST SP 800-18 Rev.1](https://csrc.nist.gov/pubs/sp/800/18/r1/final) — the per-control implementation-statement structure this appendix follows
