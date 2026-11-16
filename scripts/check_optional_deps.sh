#!/usr/bin/env bash
# UNVERIFIED: written without an Elixir toolchain; never run.
#
# Compiles ash_a2a from a throwaway consumer project that depends on it by path:
# once with none of the optional deps, then once per single optional dep added.
# Fails on a compile error or any warning emitted while compiling ash_a2a.
#
# OPTIONAL_DEPS must equal the `optional: true` deps in mix.exs;
# test/optional_deps_matrix_test.exs enforces that.
set -euo pipefail

OPTIONAL_DEPS="oban ash_oban ash_state_machine postgrex flame durable_server req_llm"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" = "--list" ]; then
  for d in $OPTIONAL_DEPS; do echo "$d"; done
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_case() {
  local extra="$1" dir="$WORK/consumer_${1:-none}"
  mkdir -p "$dir/lib"
  local extra_dep=""
  if [ -n "$extra" ]; then extra_dep=", {:$extra, \">= 0.0.0\"}"; fi
  cat >"$dir/mix.exs" <<MIX
defmodule OptionalDepsConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :optional_deps_consumer, version: "0.1.0", elixir: "~> 1.19", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:ash_a2a, path: "$REPO"}$extra_dep]
  end
end
MIX
  echo "== optional deps case: ${extra:-none}"
  (
    cd "$dir"
    mix deps.get
    # Force-compile ash_a2a itself so its warnings are visible, then fail on any.
    log="$dir/ash_a2a_compile.log"
    mix deps.compile ash_a2a --force 2>&1 | tee "$log"
    if grep -q "warning:" "$log"; then
      echo "FAIL: warnings compiling ash_a2a (extra dep: ${extra:-none})" >&2
      exit 1
    fi
    mix compile --warnings-as-errors
  )
}

run_case ""
for d in $OPTIONAL_DEPS; do run_case "$d"; done
echo "optional deps matrix: all cases compiled"
