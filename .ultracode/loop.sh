#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
ROOT="$(cd "$ROOT" && pwd -P)"
PROMPT="$ROOT/.ultracode/ULTRACODE.md"
STATE="$ROOT/.ultracode/state"
INTERVAL="${ULTRACODE_INTERVAL_SECONDS:-1800}"
DURATION="${ULTRACODE_DURATION_SECONDS:-28800}"
CYCLES=$((DURATION / INTERVAL))

export ZAI_MODEL="${ZAI_MODEL:-glm-5.3-flash}"
export ZAI_MAX_CONCURRENCY=50

command -v ultracode >/dev/null || { echo 'BLOCKED: ultracode not found' >&2; exit 127; }
command -v mix >/dev/null || { echo 'BLOCKED: mix not found' >&2; exit 127; }
[[ -f "$PROMPT" ]] || { echo "BLOCKED: missing $PROMPT" >&2; exit 66; }

cd "$ROOT"
REMOTE="$(git remote get-url origin 2>/dev/null || true)"
case "$REMOTE" in
  *seanchatmangpt/ash_a2a*) ;;
  *) echo "REFUSED: not ash_a2a: $REMOTE" >&2; exit 65 ;;
esac

mkdir -p "$STATE/runs"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN="$STATE/runs/$RUN_ID"
mkdir -p "$RUN"

subject() {
  printf 'remote=%s\nbranch=%s\nsha=%s\ndirty=%s\n' \
    "$REMOTE" \
    "$(git rev-parse --abbrev-ref HEAD)" \
    "$(git rev-parse HEAD)" \
    "$(test -n "$(git status --porcelain)" && echo true || echo false)"
}

run_swarm() {
  local cycle="$1" mode="$2" dir="$RUN/cycle-$(printf '%02d' "$cycle")"
  mkdir -p "$dir"
  subject > "$dir/subject.start"
  {
    cat "$PROMPT"
    printf '\n## Runtime envelope\n- cycle: `%s`\n- mode: `%s`\n- model: `%s`\n- exact subject:\n```text\n' "$cycle" "$mode" "$ZAI_MODEL"
    cat "$dir/subject.start"
    printf '```\n'
  } > "$dir/prompt.md"

  set +e
  ultracode launch 50 agents "$(cat "$dir/prompt.md")" >"$dir/stdout.log" 2>"$dir/stderr.log"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$dir/exit"
  subject > "$dir/subject.end"
  return "$rc"
}

START="$(date +%s)"
for ((i=1; i<=CYCLES; i++)); do
  target=$((START + (i - 1) * INTERVAL))
  now="$(date +%s)"
  (( now < target )) && sleep $((target - now))
  run_swarm "$i" OPERATE_VERIFY_REPAIR_LEARN || true
done

not_before=$((START + DURATION))
now="$(date +%s)"
(( now < not_before )) && sleep $((not_before - now))
run_swarm "$((CYCLES + 1))" FINAL_RELEASE_AUDIT || true

FINAL="$RUN/final"
mkdir -p "$FINAL"
set +e
(
  echo '== subject =='; subject
  echo '== format =='; mix format --check-formatted
  echo '== compile =='; mix compile --warnings-as-errors
  echo '== architecture =='; mix ash_a2a.verify_architecture
  echo '== tests =='; mix test
  echo '== package =='; mix hex.build
) >"$FINAL/court.stdout.log" 2>"$FINAL/court.stderr.log"
COURT_RC=$?
set -e
printf '%s\n' "$COURT_RC" > "$FINAL/court.exit"

subject > "$FINAL/subject"
mix run -e 'IO.puts(Mix.Project.config()[:version])' > "$FINAL/version" 2>/dev/null || true
HEX="$(ls -1t ./*.hex 2>/dev/null | head -1 || true)"
[[ -n "$HEX" ]] && sha256sum "$HEX" > "$FINAL/package.sha256"

{
  echo 'publication_executed=false'
  echo 'merge_executed=false'
  echo 'tag_executed=false'
  echo 'release_created=false'
  echo "court_exit=$COURT_RC"
  [[ -f "$FINAL/version" ]] && echo "version=$(cat "$FINAL/version")"
  [[ -f "$FINAL/package.sha256" ]] && cat "$FINAL/package.sha256"
} > "$FINAL/release.receipt"

printf 'evidence=%s\n' "$RUN"
