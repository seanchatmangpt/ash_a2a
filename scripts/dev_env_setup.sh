#!/usr/bin/env bash
# Reproducible verification environment for ash_a2a.
#
#   scripts/dev_env_setup.sh            full mode: ensure every component, install what is missing
#   scripts/dev_env_setup.sh --quick    PATH check + make sure Postgres is up (seconds)
#
# Idempotent, non-interactive, safe to re-run: every step first checks whether
# its component is present and reports "present" instead of reinstalling.
#
# Components (full mode):
#   apt        packages the tests need (openssh-client, build tools, libssl, unzip, ...)
#   otp        Erlang/OTP from .tool-versions, builds.hex.pm tarball, sha256-verified, into $PREFIX/otp
#   elixir     Elixir from .tool-versions, builds.hex.pm zip, sha256-verified, into $PREFIX/elixir
#   hex        mix local.hex / mix local.rebar, then mix deps.get when a dep is missing
#   postgres   PostgreSQL 16 cluster ($PGDATA, port $PGPORT), started if down
#   databases  ash_a2a_test and ash_a2a_test1..20, then mix ecto.create
#   rust       cargo build --release of native/hddl_cli (native/graphlaw_host with --graphlaw)
#   venv       parity venv via scripts/a2a_v1_1_parity/setup.sh
#   upstream   a2aproject/a2a tags v1.1.0-rc and v1.0.1 under $A2A_UPSTREAM_DIR
#
# Options:
#   --quick          see above
#   --only LIST      comma list of components to run (default: all), e.g. --only otp,elixir
#   --skip LIST      comma list of components to skip
#   --graphlaw       also build native/graphlaw_host
#   --no-apt         never call apt-get (components that need it then fail)
#   -h, --help
#
# Environment (all optional):
#   PREFIX / A2A_PREFIX     install prefix for OTP and Elixir (default /opt)
#   PGDATA / A2A_PG_DATA    Postgres data dir (default /var/lib/pgtest)
#   PGPORT / A2A_PG_PORT    Postgres port (default 55432)
#   PG_PASSWORD             password for user postgres (default postgres)
#   PG_DB_COUNT             highest ash_a2a_test<N> database (default 20)
#   A2A_UPSTREAM_DIR        clone directory of a2aproject/a2a
#   A2A_PARITY_VENV         parity venv directory
#   A2A_SETUP_DOWNLOAD_DIR  scratch dir for downloads (default: a temp dir, removed on exit)
#
# Needs root (or passwordless sudo) only for apt and for the postgres user.
# Outbound hosts: see docs/reference/environment-setup.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

[ -n "${PREFIX:-}" ] && export A2A_PREFIX="$PREFIX"
[ -n "${PGDATA:-}" ] && export A2A_PG_DATA="$PGDATA"
[ -n "${PGPORT:-}" ] && export A2A_PG_PORT="$PGPORT"
# shellcheck disable=SC1091
. "$HERE/env.sh"

PREFIX="$A2A_PREFIX"
PGDATA="$A2A_PG_DATA"
PGPORT="$A2A_PG_PORT"
PG_PASSWORD="${PG_PASSWORD:-postgres}"
PG_DB_COUNT="${PG_DB_COUNT:-20}"
PG_BIN="${PG_BIN:-/usr/lib/postgresql/16/bin}"
OTP_VERSION="$A2A_OTP_VERSION"
ELIXIR_VERSION="$A2A_ELIXIR_VERSION"
BUILDS_HOST="${BUILDS_HOST:-https://builds.hex.pm}"
OTP_PLATFORM="${OTP_PLATFORM:-ubuntu-24.04}"

QUICK=0
ONLY=""
SKIP=""
GRAPHLAW=0
APT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --only) ONLY="$2"; shift ;;
    --skip) SKIP="$2"; shift ;;
    --graphlaw) GRAPHLAW=1 ;;
    --no-apt) APT=0 ;;
    -h | --help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "dev_env_setup.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

FAILED=()
log() { printf '%-10s %s\n' "$1" "$2"; }
selected() {
  local c="$1"
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$c,"*) ;; *) return 1 ;; esac; fi
  case ",$SKIP," in *",$c,"*) return 1 ;; esac
  return 0
}
fail() { log "$1" "FAILED: $2"; FAILED+=("$1"); }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi
fi

DL_DIR="${A2A_SETUP_DOWNLOAD_DIR:-}"
CLEAN_DL=0
download_dir() {
  if [ -z "$DL_DIR" ]; then DL_DIR="$(mktemp -d)"; CLEAN_DL=1; fi
  mkdir -p "$DL_DIR"
}
cleanup() { [ "$CLEAN_DL" = 1 ] && rm -rf "$DL_DIR"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------- Postgres helpers

# Runs a command as the postgres OS user.
as_pg() {
  if [ "$(id -un)" = postgres ]; then bash -c "$1"
  elif [ "$(id -u)" -eq 0 ]; then su postgres -c "$1"
  elif [ -n "$SUDO" ]; then $SUDO su postgres -c "$1"
  else echo "need root or passwordless sudo to act as the postgres user" >&2; return 1
  fi
}
pg_up() { "$PG_BIN/pg_isready" -q -h localhost -p "$PGPORT" 2>/dev/null; }
psqlx() { PGPASSWORD="$PG_PASSWORD" "$PG_BIN/psql" -X -q -h localhost -p "$PGPORT" -U postgres -d postgres -tA "$@"; }

ensure_pg_running() {
  if pg_up; then log postgres "running on localhost:$PGPORT"; return 0; fi
  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    fail postgres "cluster $PGDATA does not exist; run without --quick"; return 1
  fi
  rm -f "$PGDATA/postmaster.pid.stale" 2>/dev/null || true
  as_pg "$PG_BIN/pg_ctl -D '$PGDATA' -o '-p $PGPORT -c listen_addresses=localhost -c max_connections=300' -l '$PGDATA/log' -w start" >/dev/null \
    || { fail postgres "pg_ctl start failed; see $PGDATA/log"; return 1; }
  log postgres "started on localhost:$PGPORT"
}

# ---------------------------------------------------------------- components

step_apt() {
  local pkgs=(openssh-client build-essential libssl-dev libncurses-dev unzip curl git git-lfs ca-certificates python3-venv postgresql-16)
  local missing=() p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  # python3-venv is only needed when the system python3 lacks ensurepip/venv.
  if [[ " ${missing[*]:-} " == *" python3-venv "* ]] && python3 -c 'import venv, ensurepip' 2>/dev/null; then
    local rest=() m
    for m in "${missing[@]}"; do [ "$m" = python3-venv ] || rest+=("$m"); done
    missing=("${rest[@]+"${rest[@]}"}")
  fi
  if [ "${#missing[@]}" -eq 0 ]; then log apt "present (${pkgs[*]})"; return 0; fi
  if [ "$APT" -eq 0 ]; then fail apt "missing ${missing[*]} and --no-apt given"; return 1; fi
  log apt "installing ${missing[*]}"
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null \
    && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null \
    || { fail apt "apt-get install ${missing[*]}"; return 1; }
  log apt "installed ${missing[*]}"
}

# builds_sha256 FILE_PATH_UNDER_BUILDS NAME: the sha256 column of builds.txt (4th field).
builds_sha256() {
  curl -fsSL "$1" | awk -v n="$2" '$1==n {print $4; exit}'
}

fetch_verified() { # URL DEST EXPECTED_SHA256
  curl -fsSL --retry 3 -o "$2" "$1" || return 1
  local actual
  actual="$(sha256sum "$2" | cut -d' ' -f1)"
  if [ "$actual" != "$3" ]; then
    echo "sha256 mismatch for $1: got $actual, expected $3" >&2
    rm -f "$2"
    return 1
  fi
}

otp_installed() {
  [ -x "$PREFIX/otp/OTP-$OTP_VERSION/bin/erl" ] &&
    [ "$(cat "$PREFIX/otp/OTP-$OTP_VERSION"/releases/*/OTP_VERSION 2>/dev/null | head -1)" = "$OTP_VERSION" ]
}

step_otp() {
  if otp_installed; then log otp "present: OTP $OTP_VERSION in $PREFIX/otp/OTP-$OTP_VERSION"; return 0; fi
  download_dir
  local name="OTP-$OTP_VERSION" sha tarball dest="$PREFIX/otp/OTP-$OTP_VERSION"
  sha="$(builds_sha256 "$BUILDS_HOST/builds/otp/$OTP_PLATFORM/builds.txt" "$name")"
  if [ -z "$sha" ]; then fail otp "no $name entry in $BUILDS_HOST/builds/otp/$OTP_PLATFORM/builds.txt"; return 1; fi
  tarball="$DL_DIR/$name.tar.gz"
  fetch_verified "$BUILDS_HOST/builds/otp/$OTP_PLATFORM/$name.tar.gz" "$tarball" "$sha" \
    || { fail otp "download or sha256 verification of $name.tar.gz"; return 1; }
  log otp "sha256 verified ($sha)"
  rm -rf "$dest.partial"
  mkdir -p "$dest.partial"
  tar -xzf "$tarball" -C "$dest.partial"
  # The tarball holds a single top-level directory with the Install script.
  local top="$dest.partial"
  if [ ! -x "$top/Install" ]; then
    top="$(find "$dest.partial" -maxdepth 2 -name Install -type f -printf '%h\n' | head -1)"
  fi
  if [ -z "$top" ] || [ ! -f "$top/Install" ]; then fail otp "no Install script in $name.tar.gz"; return 1; fi
  rm -rf "$dest"
  mv "$top" "$dest"
  rm -rf "$dest.partial"
  (cd "$dest" && ./Install -minimal "$dest" >/dev/null)
  rm -f "$tarball"
  # shellcheck disable=SC1091
  . "$HERE/env.sh"
  otp_installed || { fail otp "installed but OTP_VERSION does not read $OTP_VERSION"; return 1; }
  log otp "installed OTP $OTP_VERSION in $dest"
}

elixir_installed() {
  [ -x "$PREFIX/elixir/bin/mix" ] &&
    [ "$(cat "$PREFIX/elixir/VERSION" 2>/dev/null)" = "${ELIXIR_VERSION%%-otp-*}" ]
}

step_elixir() {
  if elixir_installed; then log elixir "present: Elixir ${ELIXIR_VERSION%%-otp-*} in $PREFIX/elixir"; return 0; fi
  download_dir
  local name="v$ELIXIR_VERSION" sha zip="$DL_DIR/v$ELIXIR_VERSION.zip" dest="$PREFIX/elixir"
  sha="$(builds_sha256 "$BUILDS_HOST/builds/elixir/builds.txt" "$name")"
  if [ -z "$sha" ]; then
    echo "elixir: no published checksum for $name; continuing unverified" >&2
    curl -fsSL --retry 3 -o "$zip" "$BUILDS_HOST/builds/elixir/$name.zip" || { fail elixir "download of $name.zip"; return 1; }
  else
    fetch_verified "$BUILDS_HOST/builds/elixir/$name.zip" "$zip" "$sha" \
      || { fail elixir "download or sha256 verification of $name.zip"; return 1; }
    log elixir "sha256 verified ($sha)"
  fi
  rm -rf "$dest.partial"
  mkdir -p "$dest.partial"
  unzip -q "$zip" -d "$dest.partial"
  rm -rf "$dest"
  mv "$dest.partial" "$dest"
  chmod +x "$dest"/bin/* 2>/dev/null || true
  rm -f "$zip"
  # shellcheck disable=SC1091
  . "$HERE/env.sh"
  elixir_installed || { fail elixir "installed but $dest/VERSION does not read ${ELIXIR_VERSION%%-otp-*}"; return 1; }
  log elixir "installed Elixir ${ELIXIR_VERSION%%-otp-*} in $dest"
}

step_hex() {
  command -v mix >/dev/null 2>&1 || { fail hex "mix not on PATH (otp/elixir step failed?)"; return 1; }
  if ls "$HOME"/.mix/archives/hex-* >/dev/null 2>&1 || ls "${MIX_HOME:-/nonexistent}"/archives/hex-* >/dev/null 2>&1; then
    log hex "present: hex archive"
  else
    mix local.hex --force >/dev/null && log hex "installed hex" || { fail hex "mix local.hex"; return 1; }
  fi
  if ls "$HOME"/.mix/elixir/*/rebar3 >/dev/null 2>&1 || ls "$HOME"/.mix/rebar3 >/dev/null 2>&1 \
    || ls "${MIX_HOME:-/nonexistent}"/elixir/*/rebar3 >/dev/null 2>&1; then
    log rebar "present: rebar3"
  else
    mix local.rebar --force >/dev/null && log rebar "installed rebar3" || { fail rebar "mix local.rebar"; return 1; }
  fi
  # mix deps.get only when a dependency is missing: read-only `mix deps` decides.
  if (cd "$REPO" && mix deps 2>&1 | grep -qE 'dependency is not available|not available|Unchecked'); then
    log deps "missing dependencies: mix deps.get"
    (cd "$REPO" && mix deps.get >/dev/null) && log deps "fetched" || { fail deps "mix deps.get"; return 1; }
  else
    log deps "present: all dependencies available"
  fi
}

step_postgres() {
  if [ ! -x "$PG_BIN/initdb" ]; then fail postgres "$PG_BIN/initdb missing (install postgresql-16)"; return 1; fi
  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    log postgres "initializing cluster in $PGDATA"
    local parent pwfile
    parent="$(dirname "$PGDATA")"
    $SUDO mkdir -p "$parent"
    pwfile="$(mktemp)"
    printf '%s\n' "$PG_PASSWORD" > "$pwfile"
    chmod 644 "$pwfile"
    $SUDO mkdir -p "$PGDATA"
    $SUDO chown postgres:postgres "$PGDATA"
    $SUDO chmod 700 "$PGDATA"
    as_pg "$PG_BIN/initdb -D '$PGDATA' -U postgres --pwfile='$pwfile' --auth-local=trust --auth-host=scram-sha-256 -E UTF8 --locale=C.UTF-8" >/dev/null \
      || { rm -f "$pwfile"; fail postgres "initdb"; return 1; }
    rm -f "$pwfile"
  else
    log postgres "present: cluster $PGDATA"
  fi
  ensure_pg_running
}

step_databases() {
  pg_up || { fail databases "Postgres not reachable on localhost:$PGPORT"; return 1; }
  local existing created=0 n db
  existing="$(psqlx -c "SELECT datname FROM pg_database")" || { fail databases "cannot query Postgres as postgres/$PG_PASSWORD"; return 1; }
  for n in "" $(seq 1 "$PG_DB_COUNT"); do
    db="ash_a2a_test$n"
    if ! grep -qx "$db" <<<"$existing"; then
      psqlx -c "CREATE DATABASE $db" >/dev/null || { fail databases "CREATE DATABASE $db"; return 1; }
      created=$((created + 1))
    fi
  done
  log databases "ash_a2a_test, ash_a2a_test1..$PG_DB_COUNT: $created created, $((PG_DB_COUNT + 1 - created)) present"
  if [ "$PGPORT" != 55432 ]; then
    log ecto "skipped: config/test.exs targets port 55432, this cluster uses $PGPORT"
  elif command -v mix >/dev/null 2>&1; then
    local flags=()
    [ -d "$REPO/_build/$MIX_ENV" ] && flags=(--no-compile)
    if (cd "$REPO" && mix ecto.create "${flags[@]+"${flags[@]}"}" >/dev/null 2>&1); then
      log ecto "mix ecto.create ok"
    else
      fail ecto "mix ecto.create (run it by hand to see the error)"
    fi
  fi
}

# up_to_date DIR BINARY...: every binary exists and is newer than all sources.
rust_current() {
  local dir="$1"; shift
  local b
  for b in "$@"; do [ -x "$dir/target/release/$b" ] || return 1; done
  [ -z "$(find "$dir/src" "$dir/Cargo.toml" "$dir/Cargo.lock" -newer "$dir/target/release/$1" -type f -print -quit 2>/dev/null)" ]
}

ensure_cargo() {
  command -v cargo >/dev/null 2>&1 && return 0
  download_dir
  log rust "cargo missing: installing rustup from static.rust-lang.org"
  curl -fsSL --retry 3 -o "$DL_DIR/rustup-init" https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init \
    && chmod +x "$DL_DIR/rustup-init" \
    && "$DL_DIR/rustup-init" -y --profile minimal --default-toolchain none >/dev/null 2>&1 \
    || return 1
  # shellcheck disable=SC1091
  . "$HERE/env.sh"
  command -v cargo >/dev/null 2>&1
}

build_rust() { # DIR BINARY...
  local dir="$1" name; name="$(basename "$1")"; shift
  if rust_current "$dir" "$@"; then log rust "present: $name ($*) up to date"; return 0; fi
  ensure_cargo || { fail rust "cargo unavailable"; return 1; }
  log rust "building $name (cargo build --release --locked)"
  (cd "$dir" && cargo build --release --locked 2>&1 | tail -3) || { fail rust "cargo build $name"; return 1; }
  rust_current "$dir" "$@" || { fail rust "$name binaries missing after build"; return 1; }
  log rust "built $name"
}

step_rust() {
  build_rust "$REPO/native/hddl_cli" hddl_cli hddl_analyze
  if [ "$GRAPHLAW" -eq 1 ]; then
    build_rust "$REPO/native/graphlaw_host" graphlaw_host
  else
    log rust "skipped: native/graphlaw_host (opt in with --graphlaw; tests skip it when unbuilt)"
  fi
}

step_venv() {
  local gen="$A2A_PARITY_VENV/a2a_v1_1_gen"
  if [ -x "$A2A_PARITY_VENV/bin/python" ] && [ -f "$gen/SHA256" ] && [ -f "$gen/a2a_pb2.py" ]; then
    log venv "present: $A2A_PARITY_VENV"
    return 0
  fi
  log venv "creating $A2A_PARITY_VENV"
  A2A_UPSTREAM="$A2A_UPSTREAM_DIR" bash "$REPO/scripts/a2a_v1_1_parity/setup.sh" "$A2A_PARITY_VENV" >/dev/null \
    && log venv "created $A2A_PARITY_VENV" || { fail venv "scripts/a2a_v1_1_parity/setup.sh"; return 1; }
}

step_upstream() {
  local dir="$A2A_UPSTREAM_DIR" tag fetched=0
  export GIT_LFS_SKIP_SMUDGE=1
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin https://github.com/a2aproject/a2a.git
    log upstream "initialized $dir"
  fi
  for tag in v1.1.0-rc v1.0.1; do
    if git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then continue; fi
    git -C "$dir" fetch -q --depth 1 origin tag "$tag" || { fail upstream "git fetch tag $tag"; return 1; }
    fetched=$((fetched + 1))
  done
  if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    git -C "$dir" checkout -q v1.1.0-rc
  fi
  if [ "$fetched" -eq 0 ]; then log upstream "present: tags v1.1.0-rc, v1.0.1 in $dir"
  else log upstream "fetched $fetched tag(s) into $dir"; fi
}

# ---------------------------------------------------------------- main

echo "ash_a2a dev environment: prefix=$PREFIX pg=localhost:$PGPORT ($PGDATA) mode=$([ "$QUICK" = 1 ] && echo quick || echo full)"

if [ "$QUICK" -eq 1 ]; then
  if command -v erl >/dev/null 2>&1 && command -v mix >/dev/null 2>&1; then
    log path "ok: $(command -v mix) (OTP $A2A_OTP_VERSION, Elixir ${A2A_ELIXIR_VERSION%%-otp-*})"
  else
    fail path "erl/mix not on PATH under $PREFIX; run scripts/dev_env_setup.sh"
  fi
  ensure_pg_running || true
else
  for c in apt otp elixir hex postgres databases rust venv upstream; do
    selected "$c" || { log "$c" "skipped by --only/--skip"; continue; }
    "step_$c" || true
  done
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "FAILED components: ${FAILED[*]}" >&2
  exit 1
fi
echo "ok"
echo "next: . scripts/env.sh"
