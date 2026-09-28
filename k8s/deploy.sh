#!/usr/bin/env bash
# Real deploy + real swarm-dispatch verification script for the
# ash_a2a distributed-agent swarm test. See k8s/README.md for the full
# design writeup and NIST-control citations this manifest set is built
# from.
#
# Usage: bash k8s/deploy.sh [kind-cluster-name]
#
# Requires: docker, kind, kubectl on PATH (all real, confirmed installed
# this session: act 0.2.87, kind 0.30.0, kubectl 1.35.2, docker 28.0.4,
# colima running).
set -euo pipefail

CLUSTER="${1:-ash-a2a-swarm}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="ash-a2a-swarm-node:local"

# Same real, disclosed friction bin/ci-local.sh's own pick_context already
# hit: this machine has more than one Docker context registered (Docker
# Desktop's desktop-linux AND Colima's own), and the "currently active"
# one is not reliably the one whose daemon is actually responding --
# confirmed once this session (`docker info` against the then-active
# desktop-linux context timed out after 10+ minutes while colima's own
# responded in well under a second). Pick a live one explicitly rather
# than trusting `docker context show`.
pick_context() {
  local current
  current="$(docker context show 2>/dev/null || echo "default")"
  local tried=()
  for ctx in "$current" colima default desktop-linux; do
    if [[ " ${tried[*]-} " == *" $ctx "* ]]; then
      continue
    fi
    tried+=("$ctx")
    if timeout 10 docker --context "$ctx" info >/dev/null 2>&1; then
      echo "$ctx"
      return 0
    fi
  done
  return 1
}

CTX="$(pick_context)" || {
  echo "No live Docker context found (tried: current active context, colima, default, desktop-linux)." >&2
  echo "Start Docker Desktop, or 'colima start', then retry." >&2
  exit 1
}
echo "Using Docker context: $CTX" >&2
export DOCKER_CONTEXT="$CTX"

echo "== Build real Docker image (context: repo root, swarm/Dockerfile) ==" >&2
docker build -f "$REPO_ROOT/swarm/Dockerfile" -t "$IMAGE" "$REPO_ROOT"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "== Create real kind cluster: $CLUSTER ==" >&2
  kind create cluster --name "$CLUSTER"
else
  echo "== Reusing existing real kind cluster: $CLUSTER ==" >&2
fi

echo "== Load real image into kind (no registry push needed) ==" >&2
kind load docker-image "$IMAGE" --name "$CLUSTER"

echo "== Apply namespace (Secrets below need it) ==" >&2
kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml"

# All Secrets are generated here, random, never committed, and only created
# when absent (re-runs keep the existing cluster identity and keys). In
# production they come from an external secret manager / cert-manager
# (k8s/overlays/prod), not from this script.
echo "== Ensure distribution cookie Secret exists ==" >&2
if ! kubectl -n ash-a2a-swarm get secret ash-a2a-swarm-cookie >/dev/null 2>&1; then
  COOKIE="$(openssl rand -hex 32)"
  kubectl -n ash-a2a-swarm create secret generic ash-a2a-swarm-cookie \
    --from-literal=cookie="$COOKIE"
fi

echo "== Ensure receipt-binding / standing-ledger key Secret exists (DEP-02/DEP-04) ==" >&2
if ! kubectl -n ash-a2a-swarm get secret ash-a2a-swarm-keys >/dev/null 2>&1; then
  kubectl -n ash-a2a-swarm create secret generic ash-a2a-swarm-keys \
    --from-literal=receipt-binding-key="$(openssl rand -base64 32)" \
    --from-literal=standing-ledger-key="$(openssl rand -base64 32)"
fi

echo "== Ensure distribution TLS Secret exists (DEP-07/SEC-10: private CA + leaf) ==" >&2
if ! kubectl -n ash-a2a-swarm get secret ash-a2a-swarm-dist-tls >/dev/null 2>&1; then
  TLS_DIR="$(mktemp -d)"
  trap 'rm -rf "$TLS_DIR"' EXIT
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
    -subj "/CN=ash-a2a-swarm-dist-ca" -keyout "$TLS_DIR/ca.key" -out "$TLS_DIR/ca.crt" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj "/CN=swarm_node" -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.csr" 2>/dev/null
  openssl x509 -req -in "$TLS_DIR/tls.csr" -CA "$TLS_DIR/ca.crt" -CAkey "$TLS_DIR/ca.key" \
    -CAcreateserial -days 90 -out "$TLS_DIR/tls.crt" 2>/dev/null
  kubectl -n ash-a2a-swarm create secret generic ash-a2a-swarm-dist-tls \
    --from-file=tls.crt="$TLS_DIR/tls.crt" \
    --from-file=tls.key="$TLS_DIR/tls.key" \
    --from-file=ca.crt="$TLS_DIR/ca.crt"
fi

echo "== Apply base manifests (kustomize: quota, SA, Services, NetworkPolicy, PDB, StatefulSet) ==" >&2
kubectl apply -k "$REPO_ROOT/k8s"

echo "== Wait for rollout: every replica Ready (readiness = /readyz, SwarmNode.Health) ==" >&2
kubectl -n ash-a2a-swarm rollout status statefulset/ash-a2a-swarm --timeout=300s
kubectl -n ash-a2a-swarm wait --for=condition=Ready pod -l app=ash-a2a-swarm --timeout=180s

# Real egress falsifier (NIST SP 800-53 SC-7(5), deny-by-default egress):
# a positive control (policy removed, real raw TCP connect to a public IP
# succeeds) followed by a negative control (policy re-applied, the
# identical call times out). Proves the NetworkPolicy actually changes
# outcome rather than just existing on disk -- see
# docs/AIRGAP_READINESS_REPORT.md test 1 for the original manual run this
# operationalizes, and the ENTERPRISE_READINESS_REPORT.md correction this
# same falsifier already forced once (an earlier draft wrongly assumed
# kind's kindnet CNI does not enforce NetworkPolicy at all).
echo "== Real egress falsifier: NetworkPolicy deny-by-default (positive control, then negative control) ==" >&2
FALSIFIER_POD="$(kubectl -n ash-a2a-swarm get pods -l app=ash-a2a-swarm -o jsonpath='{.items[0].metadata.name}')"

echo "== Positive control: remove NetworkPolicy, expect real raw TCP connect to succeed ==" >&2
kubectl -n ash-a2a-swarm delete -f "$REPO_ROOT/k8s/network-policy.yaml"
POSITIVE="$(kubectl -n ash-a2a-swarm exec "$FALSIFIER_POD" -- /app/bin/swarm_node rpc \
  'IO.inspect(:gen_tcp.connect(~c"8.8.8.8", 443, [], 5000))')"
echo "$POSITIVE" >&2

echo "== Negative control: re-apply NetworkPolicy, expect the identical call to time out ==" >&2
kubectl apply -f "$REPO_ROOT/k8s/network-policy.yaml"
# Give the re-applied policy a moment to actually be programmed by the
# CNI before testing it -- policy enforcement is not instantaneous.
sleep 3
NEGATIVE="$(kubectl -n ash-a2a-swarm exec "$FALSIFIER_POD" -- /app/bin/swarm_node rpc \
  'IO.inspect(:gen_tcp.connect(~c"8.8.8.8", 443, [], 5000))')"
echo "$NEGATIVE" >&2

if ! echo "$POSITIVE" | grep -q '{:ok,' || ! echo "$NEGATIVE" | grep -q '{:error, :timeout}'; then
  echo "== FAILED: egress falsifier did not show the expected connect-without-policy / timeout-with-policy split (NetworkPolicy enforcement unverified) ==" >&2
  exit 1
fi
echo "== REAL egress deny-by-default falsifier passed (NetworkPolicy enforcement confirmed, not assumed) ==" >&2

echo "== Real swarm-dispatch probe (from pod 0, against real peer pods) ==" >&2
PODS=($(kubectl -n ash-a2a-swarm get pods -l app=ash-a2a-swarm -o jsonpath='{.items[*].metadata.name}'))
echo "Real pods: ${PODS[*]}" >&2

# No sleep: readiness (SWARM_MIN_PEERS=1) already means each pod has
# connected peers.

# `rpc` evaluates the expression in the ALREADY-RUNNING remote node and
# returns/prints its result -- it does not affect that node's lifecycle,
# so nothing here may call System.halt/1 (that would halt the real,
# still-needed swarm pod, not just this rpc connection). Verification is
# by grepping the real JSON line `SwarmNode.Probe.run/0` prints for
# `"swarm_dispatch_verified":true` -- this script's own exit code, not
# anything evaluated remotely.
PROBE_OUTPUT="$(kubectl -n ash-a2a-swarm exec "${PODS[0]}" -- \
  /app/bin/swarm_node rpc "SwarmNode.Probe.run()")"
echo "$PROBE_OUTPUT" >&2

if ! echo "$PROBE_OUTPUT" | grep -q '"swarm_dispatch_verified":true'; then
  echo "== FAILED: no verified cross-pod dispatch in probe output above ==" >&2
  exit 1
fi
echo "== REAL cross-pod A2A dispatch verified ==" >&2

echo "== Real network isolation regression check (permanent -- was previously a manual one-off, see k8s/README.md) ==" >&2
bash "$REPO_ROOT/k8s/verify_network_isolation.sh"

echo "== Real resilience/chaos test: kill one pod, verify self-heal + swarm reformation ==" >&2
VICTIM="${PODS[${#PODS[@]}-1]}"
echo "Killing pod: $VICTIM" >&2
kubectl -n ash-a2a-swarm delete pod "$VICTIM" --wait=true
# The StatefulSet recreates the pod under the same name and PVC; wait until
# it is Ready again (i.e. /readyz passes: rejoined peers, GraphLaw loaded).
kubectl -n ash-a2a-swarm rollout status statefulset/ash-a2a-swarm --timeout=180s
kubectl -n ash-a2a-swarm wait --for=condition=Ready pod "$VICTIM" --timeout=180s

SURVIVOR="${PODS[0]}"
POST_CHAOS_OUTPUT="$(kubectl -n ash-a2a-swarm exec "$SURVIVOR" -- \
  /app/bin/swarm_node rpc "SwarmNode.Probe.run()")"
echo "$POST_CHAOS_OUTPUT" >&2

if echo "$POST_CHAOS_OUTPUT" | grep -q '"swarm_dispatch_verified":true'; then
  echo "== REAL post-chaos swarm reformation verified: killed pod replaced, new peer auto-joined, cross-pod dispatch still works ==" >&2
  exit 0
else
  echo "== FAILED: swarm did not reform a verified dispatch after killing a pod ==" >&2
  exit 1
fi
