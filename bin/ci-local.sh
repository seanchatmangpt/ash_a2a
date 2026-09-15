#!/usr/bin/env bash
# Runs the real .github/workflows/ci.yml locally via `act`, so the exact
# same recipe hosted GitHub Actions runs (ubuntu-latest, a real Postgres:16
# service container, pinned Rust/Elixir/OTP toolchains, the real
# ferroplan-backed HDDL CLI build, mix format/compile/test) can be
# reproduced on this machine without the ad hoc trial-and-error this repo
# hit doing it by hand once already (Apple-Silicon architecture warnings,
# runner-image selection, and picking the wrong/dead Docker context).
#
# `.actrc` (repo root) pins the runner image + container architecture;
# this script's own job is picking a Docker context that is actually alive
# right now -- this machine has been observed with more than one context
# registered (colima, desktop-linux, default), and which one is really
# running the daemon changes between sessions, so nothing here is
# hardcoded to whichever one happened to work when this script was
# written.
#
# KNOWN REAL LIMITATION, disclosed rather than papered over: on this
# Apple-Silicon + Docker Desktop host, 8 real configurations (native arm64
# images, --container-architecture linux/amd64 under emulation, -u root,
# multiple catthehacker/ubuntu tags) were all tried and all failed --
# every single one inside the third-party erlef/setup-beam@v1 action's own
# OTP/Elixir install step, before this repo's own CI logic (mix deps.get,
# the Rust hddl_cli build, mix test) ever ran. Root cause: the pinned OTP
# 28.0.4 arm64 build needs libcrypto.so.1.1 (OpenSSL 1.1), which the
# available act runner images do not ship; amd64-under-emulation instead
# hits an erlexec binary-format mismatch. This script fixes the Docker
# CONTEXT-selection friction (a real problem: a bare `act` run previously
# picked a dead context, or collided with this repo's own dev Postgres
# container on port 55432) -- it does NOT, by itself, make a full
# `act push -j test` succeed end to end on this class of machine. Treat a
# real hosted GitHub Actions run on the same SHA (`gh run list`) as the
# authoritative local-parity signal until an OTP/OpenSSL-1.1-capable
# runner image is found or built; do not assume this script "fixes" act,
# only that it removes the context/Postgres-port friction layer.
set -euo pipefail

cd "$(dirname "$0")/.."

pick_context() {
  local current
  current="$(docker context show 2>/dev/null || echo "default")"
  local tried=()
  for ctx in "$current" colima default desktop-linux; do
    if [[ " ${tried[*]-} " == *" $ctx "* ]]; then
      continue
    fi
    tried+=("$ctx")
    if docker --context "$ctx" info >/dev/null 2>&1; then
      echo "$ctx"
      return 0
    fi
  done
  return 1
}

if ! command -v act >/dev/null 2>&1; then
  echo "act is not installed. Install it (e.g. 'brew install act') and retry." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH." >&2
  exit 1
fi

CTX="$(pick_context)" || {
  echo "No live Docker context found (tried: current active context, colima, default, desktop-linux)." >&2
  echo "Start Docker Desktop, or 'colima start', then retry." >&2
  exit 1
}

echo "Using Docker context: $CTX" >&2
DOCKER_HOST="$(docker context inspect "$CTX" --format '{{.Endpoints.docker.Host}}')"
export DOCKER_HOST

# `push` is the simpler event to simulate locally (no PR event JSON needed)
# and matches this workflow's own `on: push: branches: [main]` trigger.
exec act push -j test "$@"
