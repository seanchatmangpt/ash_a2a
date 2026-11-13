#!/usr/bin/env bash
# Fail-closed sleep gate: every Process.sleep in lib/ (and sa2a_crypto/lib) needs an adjacent
# `# SLEEP-CLASS: SCHEDULING` or `# SLEEP-CLASS: POLL-STEP` annotation
# (same line, or within the 3 preceding lines). Exit 1 on violations, 2 on tool/root error.
command -v rg >/dev/null 2>&1 || { echo "sleep_gate: rg missing, refusing to fake-pass"; exit 2; }
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
[ -d "$ROOT/lib" ] || { echo "sleep_gate: missing lib root $ROOT/lib, refusing to fake-pass"; exit 2; }
roots=("$ROOT/lib")
[ -d "$ROOT/sa2a_crypto/lib" ] && roots+=("$ROOT/sa2a_crypto/lib")
out=$(mktemp) || exit 2
trap 'rm -f "$out"' EXIT
rg -n --no-heading '^\s*[^#\s].*Process\.sleep\(|&Process\.sleep/1|^\s*Process\.sleep' "${roots[@]}" --glob '*.ex' > "$out"
rc=$?
if [ "$rc" -gt 1 ]; then echo "sleep_gate: rg failed (exit $rc), refusing to fake-pass"; exit 2; fi
bad=0
while IFS=: read -r file line _rest; do
  start=$(( line > 3 ? line - 3 : 1 ))
  if ! sed -n "${start},${line}p" "$file" | rg -q 'SLEEP-CLASS: (SCHEDULING|POLL-STEP)'; then
    echo "UNANNOTATED: $file:$line"
    bad=$((bad + 1))
  fi
done < "$out"
if [ "$bad" -gt 0 ]; then echo "sleep_gate: $bad unannotated Process.sleep site(s)"; exit 1; fi
echo "sleep_gate: clean"
