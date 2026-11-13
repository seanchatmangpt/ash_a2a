#!/bin/bash
# Stop beam4pm A2A agent: recorded PID first, then any remaining listener on the port.
PORT="${1:-4211}"
PIDFILE="${TMPDIR:-/tmp}/beam4pm-a2a-$PORT.pid"
pids=""
[ -f "$PIDFILE" ] && pids=$(cat "$PIDFILE")
pids="$pids $(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null)"
pids=$(echo $pids)
[ -n "$pids" ] && kill $pids 2>/dev/null
rm -f "$PIDFILE"
echo "stopped: ${pids:-none}"
