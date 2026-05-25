#!/bin/bash
# apache-stop.sh <slug>
#   Kill apache for a feature. Updates state.json.

set -eu

SLUG="${1:-}"
[[ -z "$SLUG" ]] && { echo "usage: apache-stop.sh <slug>" >&2; exit 2; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/../lib/worktree-state.sh"

if ! state_has "$SLUG"; then
    echo "ERROR: feature '$SLUG' not registered" >&2
    exit 2
fi

PORT=$(state_get "$SLUG" | jq -r '.port')
PID=$(state_get "$SLUG" | jq -r '.apache_pid // empty')

killed=0
if state_pid_alive "$PID"; then
    kill -TERM "$PID" 2>/dev/null || true
    sleep 0.5
    kill -9 "$PID" 2>/dev/null || true
    killed=1
fi

# Also kill anything still on the port (safety net)
other=$(lsof -ti ":$PORT" 2>/dev/null || true)
if [[ -n "$other" ]]; then
    echo "$other" | xargs kill -9 2>/dev/null || true
    killed=1
fi

rm -f "/tmp/apache-$PORT.pid" "/tmp/apache-$PORT.conf"

state_set "$SLUG" "apache_pid" "null"
state_set "$SLUG" "apache_running" "false"

if [[ $killed -eq 1 ]]; then
    echo "Apache stopped for $SLUG (port $PORT freed)"
else
    echo "No apache running for $SLUG"
fi
