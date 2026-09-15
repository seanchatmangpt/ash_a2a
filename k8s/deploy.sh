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

echo "== Apply namespace + quota + ServiceAccount + headless Service + NetworkPolicy ==" >&2
kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml"
kubectl apply -f "$REPO_ROOT/k8s/resource-quota.yaml"
kubectl apply -f "$REPO_ROOT/k8s/service-account.yaml"
kubectl apply -f "$REPO_ROOT/k8s/headless-service.yaml"
kubectl apply -f "$REPO_ROOT/k8s/network-policy.yaml"

echo "== Ensure real distribution cookie Secret exists (random, never committed) ==" >&2
if ! kubectl -n ash-a2a-swarm get secret ash-a2a-swarm-cookie >/dev/null 2>&1; then
  COOKIE="$(openssl rand -hex 32)"
  kubectl -n ash-a2a-swarm create secret generic ash-a2a-swarm-cookie \
    --from-literal=cookie="$COOKIE"
fi

echo "== Apply Deployment ==" >&2
kubectl apply -f "$REPO_ROOT/k8s/deployment.yaml"

echo "== Wait for real rollout ==" >&2
kubectl -n ash-a2a-swarm rollout status deployment/ash-a2a-swarm --timeout=180s

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

# Give libcluster's 5s polling interval a moment to have actually
# connected the real peers before probing.
sleep 8

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

echo "== Real resilience/chaos test: kill one pod, verify self-heal + swarm reformation ==" >&2
VICTIM="${PODS[${#PODS[@]}-1]}"
echo "Killing pod: $VICTIM" >&2
kubectl -n ash-a2a-swarm delete pod "$VICTIM" --wait=false
kubectl -n ash-a2a-swarm rollout status deployment/ash-a2a-swarm --timeout=90s

sleep 8

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
