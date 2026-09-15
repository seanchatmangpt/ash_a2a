#!/usr/bin/env bash
# Real, permanent network-isolation regression check for the ash_a2a
# distributed-agent swarm test.
#
# This automates what was previously a one-off manual reproduction (see
# docs/AIRGAP_READINESS_REPORT.md's "1. Egress falsifier" and
# docs/ENTERPRISE_READINESS_REPORT.md's "Correction (re-derived from a
# real falsifier, not assumed)" section) into a repeatable, scriptable
# step, so a future NetworkPolicy regression (someone loosens or deletes
# the egress-deny rule in k8s/network-policy.yaml) fails a real command
# on every deploy instead of relying on someone re-running the manual
# steps by hand again.
#
# What it proves, every run: the exact same real `:gen_tcp.connect/4`
# call to a public IP (8.8.8.8:443 -- an IP, not a hostname, so DNS
# resolution is not what's being tested) changes real outcome depending
# on whether k8s/network-policy.yaml is applied:
#   - policy REMOVED (positive control): connect succeeds ({:ok, _})
#   - policy RE-APPLIED (negative control, the real production posture):
#     connect times out ({:error, :timeout})
# If either control fails to produce its expected result, egress
# isolation is not actually doing anything real and this script exits 1.
#
# Usage: bash k8s/verify_network_isolation.sh [namespace] [app-label]
#
# Requires: kubectl on PATH, pointed at a live cluster with the ash_a2a
# swarm Deployment and k8s/network-policy.yaml already applied.
# k8s/deploy.sh runs this automatically after the initial swarm-dispatch
# probe and before the resilience/chaos test, as a permanent step.
set -uo pipefail

NAMESPACE="${1:-ash-a2a-swarm}"
APP_LABEL="${2:-ash-a2a-swarm}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_FILE="$REPO_ROOT/k8s/network-policy.yaml"
KUBECTL_TIMEOUT_SECS="${KUBECTL_TIMEOUT_SECS:-30}"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "== FAILED: $POLICY_FILE not found ==" >&2
  exit 1
fi

POD="$(kubectl -n "$NAMESPACE" get pods -l "app=$APP_LABEL" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -z "$POD" ]]; then
  echo "== FAILED: no running pod found for app=$APP_LABEL in namespace $NAMESPACE ==" >&2
  exit 1
fi
echo "== Real network-isolation regression check against pod: $POD ==" >&2

connect_probe() {
  timeout "$KUBECTL_TIMEOUT_SECS" kubectl -n "$NAMESPACE" exec "$POD" -- /app/bin/swarm_node rpc \
    'IO.inspect(:gen_tcp.connect(~c"8.8.8.8", 443, [], 5000))' 2>&1
}

# Real invariant this script upholds regardless of outcome: the
# NetworkPolicy is always left APPLIED on exit (success, assertion
# failure, exec error, or interrupt) -- the secure default state -- via
# an EXIT trap. `set -e` is deliberately NOT used (see below): with it,
# a transient failure of the exec call between "delete" and "apply"
# would abort the script mid-way and leave the cluster with its egress
# NetworkPolicy removed, which is exactly the regression this script
# exists to catch, not cause.
POLICY_RESTORED=0
restore_policy() {
  if [[ "$POLICY_RESTORED" -eq 0 ]]; then
    echo "== Restoring NetworkPolicy (final state, always applied): kubectl apply -f $POLICY_FILE ==" >&2
    kubectl apply -f "$POLICY_FILE" >/dev/null 2>&1 || \
      echo "== WARNING: failed to re-apply $POLICY_FILE on exit -- verify cluster NetworkPolicy state by hand ==" >&2
    POLICY_RESTORED=1
  fi
}
trap restore_policy EXIT

echo "== Positive control: removing NetworkPolicy, expecting real egress to SUCCEED ==" >&2
if ! kubectl -n "$NAMESPACE" delete -f "$POLICY_FILE" --ignore-not-found; then
  echo "== FAILED: could not delete NetworkPolicy from $POLICY_FILE ==" >&2
  exit 1
fi
# Give the CNI a moment to actually retract the now-removed policy's
# rules before probing.
sleep 3

POSITIVE_OUTPUT="$(connect_probe)"
echo "$POSITIVE_OUTPUT" >&2

echo "== Re-applying NetworkPolicy (real production posture) ==" >&2
if ! kubectl apply -f "$POLICY_FILE"; then
  echo "== FAILED: could not apply NetworkPolicy from $POLICY_FILE ==" >&2
  exit 1
fi
POLICY_RESTORED=1
# Give the CNI a moment to actually enforce the re-applied policy before
# probing again -- matches the timing the manual reproduction this
# script replaces used.
sleep 3

echo "== Negative control: NetworkPolicy applied, expecting real egress to BLOCK ==" >&2
NEGATIVE_OUTPUT="$(connect_probe)"
echo "$NEGATIVE_OUTPUT" >&2

FAILED=0

if ! echo "$POSITIVE_OUTPUT" | grep -q '{:ok,'; then
  echo "== FAILED: positive control did not connect with policy removed -- this falsifier is not exercising a real difference (broken test, not proof of isolation) ==" >&2
  FAILED=1
fi

if ! echo "$NEGATIVE_OUTPUT" | grep -q '{:error, :timeout}'; then
  echo "== FAILED: negative control did not block with policy applied -- REAL EGRESS ISOLATION REGRESSION ==" >&2
  FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "== FAILED: network isolation regression check did not reproduce the expected positive/negative control outcome ==" >&2
  exit 1
fi

echo "== REAL network isolation verified: egress blocked with NetworkPolicy applied, confirmed via a real positive+negative control ==" >&2
