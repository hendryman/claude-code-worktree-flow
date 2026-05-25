#!/bin/bash
# reassign-port.sh <slug>
#   Allocate a fresh port for <slug> that doesn't collide with any other
#   active feature in state.json, update the feature's .port and .url, and
#   exit. Useful for reconciling legacy state files that accumulated port
#   collisions before the collision-aware allocator landed.
#
# Does NOT restart Apache — if one is running on the old port, the caller
# should stop it first (/wt-stop) and start fresh (/wt-apache) afterwards.

set -eu

SLUG="${1:-}"

if [[ -z "$SLUG" ]]; then
    echo "ERROR: usage: reassign-port.sh <slug>" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/../lib/worktree-state.sh"

state_init

if ! state_has "$SLUG"; then
    echo "ERROR: feature '$SLUG' not registered" >&2
    exit 2
fi

ABS_PATH=$(state_get "$SLUG" | jq -r '.abs_path')
OLD_PORT=$(state_get "$SLUG" | jq -r '.port')
EX_PID=$(state_get "$SLUG" | jq -r '.apache_pid // empty')

if state_pid_alive "$EX_PID"; then
    echo "ERROR: apache still running for '$SLUG' on :$OLD_PORT (pid $EX_PID)." >&2
    echo "Stop it first: bash $SCRIPT_DIR/apache-stop.sh $SLUG" >&2
    exit 1
fi

NEW_PORT=$(state_allocate_port "$ABS_PATH" "$SLUG")
if [[ "$NEW_PORT" == "$OLD_PORT" ]]; then
    echo "Port for '$SLUG' unchanged (:$OLD_PORT — no collision)."
    exit 0
fi

state_set "$SLUG" "port" "$NEW_PORT"
state_set "$SLUG" "url" "\"http://localhost:$NEW_PORT/\""
state_set "$SLUG" "apache_log" "\"/tmp/apache-$NEW_PORT.log\""

echo "Reassigned '$SLUG': :$OLD_PORT → :$NEW_PORT"
echo "Next: bash $SCRIPT_DIR/apache-start.sh $SLUG"
