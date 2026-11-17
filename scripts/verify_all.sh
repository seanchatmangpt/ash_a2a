#!/usr/bin/env bash
# One command, every gate, one verdict line each.
#
#   scripts/verify_all.sh                 quick tier: compile, format, proofs (no test suite)
#   scripts/verify_all.sh --tests         quick tier + `mix test` (default test tier)
#   scripts/verify_all.sh --full          quick tier + `mix test.all` (what CI runs)
#   scripts/verify_all.sh --mutation      also run the mutation gate (see below)
#   scripts/verify_all.sh --json          machine-readable result on stdout (progress on stderr)
#   scripts/verify_all.sh --logs DIR      keep gate logs in DIR (default: a fresh temp dir, path printed)
#
# Gates, in order:
#   compile    mix compile --warnings-as-errors
#   format     mix format --check-formatted
#   prove      mix ash_a2a.sim --prove
#   parity     mix ash_a2a.sim --parity --strict      (needs the parity venv: scripts/dev_env_setup.sh)
#   mcp        python3 scripts/mcp_drive.py
#   mutation   mix ash_a2a.chicago.mutate --require-killed   (ONLY with --mutation)
#   tests      mix test (--tests) or mix test.all (--full)
#
# The mutation gate hot-loads mutated modules into this checkout's build and
# rewrites loaded code while it runs; any other mix command or test run sharing
# the same _build during that time can observe mutants. It is therefore refused
# unless --mutation is passed, and --mutation should be used together with a
# private MIX_BUILD_PATH.
#
# Running next to other work: set a private build path so compilation and the
# proofs do not collide with other mix processes, e.g.
#   MIX_BUILD_PATH=/tmp/a2a_verify_build scripts/verify_all.sh
# (the first run compiles everything from scratch). MIX_TEST_PARTITION selects
# the test database ash_a2a_test<N> and is passed through.
#
# Exit status: 0 when every gate that ran passed (skips are not failures),
# 1 when any gate failed, 2 on a usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
. "$HERE/env.sh"
cd "$REPO" || exit 2

JSON=0 TESTS=none MUTATION=0 LOGDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --tests) [ "$TESTS" = all ] || TESTS=default ;;
    --full) TESTS=all ;;
    --mutation) MUTATION=1 ;;
    --logs) LOGDIR="$2"; shift ;;
    -h | --help) sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "verify_all.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$LOGDIR" ] || LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/verify_all.XXXXXX")"
mkdir -p "$LOGDIR"

ROWS=()
FAILS=0
json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

say() { if [ "$JSON" = 1 ]; then echo "$*" >&2; else echo "$*"; fi; }

# gate NAME CMD...
gate() {
  local name="$1"; shift
  local log="$LOGDIR/$name.log" start end rc verdict
  start=$(date +%s)
  "$@" >"$log" 2>&1
  rc=$?
  end=$(date +%s)
  if [ "$rc" -eq 0 ]; then verdict=PASS; else verdict=FAIL; FAILS=$((FAILS + 1)); fi
  record "$name" "$verdict" "$((end - start))" "$* (exit $rc)" "$log"
  if [ "$verdict" = FAIL ]; then tail -n 8 "$log" | sed 's/^/    | /' >&2; fi
}

skip() { # NAME REASON
  record "$1" SKIP 0 "$2" ""
}

record() { # NAME VERDICT SECS DETAIL LOG
  local detail="$4"
  say "$(printf '%-9s %-4s %4ss  %s%s' "$1" "$2" "$3" "$detail" "${5:+  [log: $5]}")"
  ROWS+=("{\"gate\":$(json_escape "$1"),\"verdict\":\"$2\",\"seconds\":$3,\"detail\":$(json_escape "$detail"),\"log\":$(json_escape "$5")}")
}

if ! command -v mix >/dev/null 2>&1; then
  echo "verify_all.sh: mix not on PATH; run scripts/dev_env_setup.sh" >&2
  exit 1
fi

# Postgres must be up for the proofs and tests; --quick starts it when needed.
"$HERE/dev_env_setup.sh" --quick >"$LOGDIR/env.log" 2>&1 || {
  say "env       FAIL    0s  scripts/dev_env_setup.sh --quick failed (see $LOGDIR/env.log)"
  tail -n 5 "$LOGDIR/env.log" >&2
  FAILS=$((FAILS + 1))
}

gate compile mix compile --warnings-as-errors
gate format mix format --check-formatted
gate prove mix ash_a2a.sim --prove
gate parity mix ash_a2a.sim --parity --strict
gate mcp python3 scripts/mcp_drive.py

if [ "$MUTATION" = 1 ]; then
  gate mutation mix ash_a2a.chicago.mutate --require-killed
else
  skip mutation "refused without --mutation: it hot-loads mutated modules into this checkout's build and can corrupt concurrent mix/test runs sharing _build (use a private MIX_BUILD_PATH)"
fi

case "$TESTS" in
  all) gate tests mix test.all ;;
  default) gate tests mix test ;;
  none) skip tests "not requested (--tests runs mix test, --full runs mix test.all)" ;;
esac

if [ "$FAILS" -eq 0 ]; then verdict=PASS; else verdict=FAIL; fi
say "verdict   $verdict  ($FAILS failed gate(s); logs in $LOGDIR)"
if [ "$JSON" = 1 ]; then
  printf '{"verdict":"%s","failed":%d,"logs":%s,"gates":[%s]}\n' \
    "$verdict" "$FAILS" "$(json_escape "$LOGDIR")" "$(IFS=,; echo "${ROWS[*]}")"
fi
[ "$FAILS" -eq 0 ]
