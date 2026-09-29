#!/usr/bin/env bash
# Source this file to put the .tool-versions Erlang/OTP and Elixir first on PATH.
# `source scripts/toolchain.sh` (do not execute). Fails loudly if either is not installed.
# Why: a shell without asdf shims can silently resolve a different Elixir/OTP than CI,
# which pins .tool-versions strictly (SC-09).
_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
_erl="$(awk '$1=="erlang"{print $2}' "$_root/.tool-versions")"
_ex="$(awk '$1=="elixir"{print $2}' "$_root/.tool-versions")"
_erl_dir="$HOME/.asdf/installs/erlang/$_erl"
_ex_dir="$HOME/.asdf/installs/elixir/$_ex"
if [ ! -d "$_erl_dir/bin" ] || [ ! -d "$_ex_dir/bin" ]; then
  echo "toolchain.sh: missing asdf install (erlang $_erl or elixir $_ex)" >&2
  return 1 2>/dev/null || exit 1
fi
export PATH="$_ex_dir/bin:$_erl_dir/bin:$PATH"
export MIX_HOME="$HOME/.mix-$_erl"
export HEX_HOME="$HOME/.hex-$_erl"
unset _root _erl _ex _erl_dir _ex_dir
