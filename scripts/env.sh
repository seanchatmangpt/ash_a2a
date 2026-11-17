# shellcheck shell=bash
# Source this file (do not execute): `. scripts/env.sh`
#
# Puts the .tool-versions Erlang/OTP and Elixir first on PATH and exports the
# settings every proof and test command expects. Sourced by scripts/dev_env_setup.sh,
# scripts/verify_all.sh, scripts/toolchain.sh and documented in
# docs/reference/environment-setup.md. Safe to source repeatedly; sets no shell options.
#
# Overridable before sourcing:
#   A2A_PREFIX        install prefix for OTP and Elixir (default /opt)
#   A2A_UPSTREAM_DIR  clone of a2aproject/a2a (default /home/user/a2aproject/a2a)
#   A2A_PARITY_VENV   parity venv (default /tmp/a2a_v1_1_parity/venv)
#   MIX_ENV           default test

_a2a_env_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
_a2a_otp="$(awk '$1=="erlang"{print $2}' "$_a2a_env_root/.tool-versions")"
A2A_PREFIX="${A2A_PREFIX:-/opt}"
A2A_OTP_VERSION="$_a2a_otp"
A2A_ELIXIR_VERSION="$(awk '$1=="elixir"{print $2}' "$_a2a_env_root/.tool-versions")"
A2A_UPSTREAM_DIR="${A2A_UPSTREAM_DIR:-/home/user/a2aproject/a2a}"
A2A_UPSTREAM="${A2A_UPSTREAM:-$A2A_UPSTREAM_DIR}"
A2A_PARITY_VENV="${A2A_PARITY_VENV:-/tmp/a2a_v1_1_parity/venv}"
export A2A_PREFIX A2A_OTP_VERSION A2A_ELIXIR_VERSION A2A_UPSTREAM_DIR A2A_UPSTREAM A2A_PARITY_VENV

_a2a_add_path() {
  [ -d "$1" ] || return 0
  case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac
}
_a2a_add_path "$HOME/.cargo/bin"
_a2a_add_path "$A2A_PREFIX/otp/OTP-$_a2a_otp/bin"
_a2a_add_path "$A2A_PREFIX/elixir/bin"
export PATH

export LANG=C.UTF-8 LC_ALL=C.UTF-8
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"
export MIX_ENV="${MIX_ENV:-test}"

# Test database (see config/test.exs): real Postgres on localhost:55432.
export A2A_PG_PORT="${A2A_PG_PORT:-55432}"
export A2A_PG_DATA="${A2A_PG_DATA:-/var/lib/pgtest}"

unset _a2a_env_root _a2a_otp
unset -f _a2a_add_path
