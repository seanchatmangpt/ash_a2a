#!/bin/bash
# Start beam4pm's A2A agent out-of-tree (ash_a2a never compiles beam4pm).
# usage: scripts/beam4pm_up.sh [port]   prints the agent base URL on success.
# Records the BEAM PID in ${TMPDIR:-/tmp}/beam4pm-a2a-<port>.pid.
set -u
PORT="${1:-4211}"
B4="${BEAM4PM_DIR:-$HOME/beam4pm}"
TMP="${TMPDIR:-/tmp}"
LOG="$TMP/beam4pm-a2a-$PORT.log"
PIDFILE="$TMP/beam4pm-a2a-$PORT.pid"
[ -d "$B4" ] || { echo "beam4pm checkout not found: $B4" >&2; exit 2; }
cd "$B4" || exit 2
# lock fds closed (9>&-) so the BEAM never inherits a harness flock
MIX_ENV="${BEAM4PM_MIX_ENV:-test}" nohup mix run --no-halt -e "
spawn(fn ->
  {:ok, _} = Bandit.start_link(plug: BeamPM.A2ARouter, port: $PORT, ip: {127, 0, 0, 1})
  receive do :never -> :ok end
end)
IO.puts(\"A2A_UP\")" > "$LOG" 2>&1 9>&- &
BEAM_PID=$!
echo "$BEAM_PID" > "$PIDFILE"
# bounded deadline poll on an observable (the agent card), no fixed sleep
deadline=$(( $(date +%s) + 240 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! kill -0 "$BEAM_PID" 2>/dev/null; then
    echo "beam4pm BEAM (pid $BEAM_PID) died before serving; see $LOG" >&2
    rm -f "$PIDFILE"; exit 1
  fi
  for path in agent-card.json agent.json; do
    body=$(curl -sf "http://127.0.0.1:$PORT/a2a/.well-known/$path") || continue
    if printf '%s' "$body" | grep -q '"name"'; then
      echo "http://127.0.0.1:$PORT/a2a"; exit 0
    fi
  done
  sleep 1  # SLEEP-CLASS: POLL-STEP bounded by the deadline above
done
echo "beam4pm agent card not reachable within deadline; see $LOG" >&2
kill "$BEAM_PID" 2>/dev/null; rm -f "$PIDFILE"; exit 1
