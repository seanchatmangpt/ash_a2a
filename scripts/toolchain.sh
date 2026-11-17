#!/usr/bin/env bash
# Source this file to put the .tool-versions Erlang/OTP and Elixir first on PATH.
# `source scripts/toolchain.sh` (do not execute). Kept for existing docs and
# bin/a2a-sim-mcp; it is now a thin wrapper over scripts/env.sh.
# Why: a shell without the pinned toolchain can silently resolve a different
# Elixir/OTP than CI, which pins .tool-versions strictly (SC-09).
# Fails loudly if the pinned Elixir or OTP is not installed
# (install with scripts/dev_env_setup.sh).
_tc_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$_tc_dir/env.sh"
if ! command -v erl >/dev/null 2>&1 || ! command -v mix >/dev/null 2>&1; then
  echo "toolchain.sh: missing OTP $A2A_OTP_VERSION or Elixir $A2A_ELIXIR_VERSION under $A2A_PREFIX; run scripts/dev_env_setup.sh" >&2
  unset _tc_dir
  return 1 2>/dev/null || exit 1
fi
unset _tc_dir
