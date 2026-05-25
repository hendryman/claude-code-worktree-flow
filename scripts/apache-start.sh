#!/bin/bash
# apache-start.sh [<slug>]
#   Start (or restart) apache for a feature. If <slug> omitted, derive from $PWD.
#   Spawns detached. Safe to call repeatedly — idempotent.

set -eu

SLUG="${1:-}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/../lib/worktree-state.sh"

state_init

if [[ -z "$SLUG" ]]; then
    SLUG=$(state_slug_for_pwd)
    if [[ -z "$SLUG" ]]; then
        echo "ERROR: not inside a registered worktree and no slug given" >&2
        exit 2
    fi
fi

if ! state_has "$SLUG"; then
    echo "ERROR: feature '$SLUG' not registered" >&2
    exit 2
fi

ABS_PATH=$(state_get "$SLUG" | jq -r '.abs_path')
PORT=$(state_get "$SLUG" | jq -r '.port')
EXISTING_PID=$(state_get "$SLUG" | jq -r '.apache_pid // empty')
LOG_FILE="/tmp/apache-$PORT.log"

# Read optional deep-link path from the main checkout's .claude/worktree-flow.json.
# REPO_ROOT is always two levels above .worktrees/<slug>/.
REPO_ROOT=$(cd "$ABS_PATH/../.." 2>/dev/null && pwd || echo "")
URL_PATH="/"
if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/.claude/worktree-flow.json" ]]; then
    p=$(jq -r '.default_url_path // "/"' "$REPO_ROOT/.claude/worktree-flow.json" 2>/dev/null || echo "/")
    [[ -n "$p" && "$p" != "null" ]] && URL_PATH="$p"
fi
FULL_URL="http://localhost:$PORT$URL_PATH"

print_banner() {
    local url="$1"
    # Do NOT auto-open the browser — the URL is printed below; the user
    # opens it themselves. Auto-opening was spawning a fresh tab on every
    # /wt-create / /wt-resume / /wt-apache call, which the user found
    # disruptive.
    cat << EOF

Editing:  $url
Next:     /wt-commit   (snapshot progress + push)
          /wt-merge    (PR + merge + teardown)
          /wt-stop     (pause Apache without losing the worktree)
          /wt-abandon  (throw everything away)
EOF
}

if state_pid_alive "$EXISTING_PID"; then
    echo "Apache already running for $SLUG (pid $EXISTING_PID) on :$PORT"
    print_banner "$FULL_URL"
    exit 0
fi

# Cross-slug port collision guard. If another registered feature has a live
# Apache on the same port, refuse to steal it. This shouldn't happen with
# the collision-aware allocator in state_allocate_port, but older entries
# in state.json may still overlap; surface the conflict instead of silently
# stomping.
OTHER_SLUG=$(state_port_owner "$PORT" "$SLUG")
if [[ -n "$OTHER_SLUG" ]]; then
    OTHER_PID=$(state_get "$OTHER_SLUG" | jq -r '.apache_pid // empty')
    echo "ERROR: port :$PORT is in use by feature '$OTHER_SLUG' (pid $OTHER_PID)." >&2
    echo "Legacy collision — run:" >&2
    echo "  bash $SCRIPT_DIR/apache-stop.sh $OTHER_SLUG  # free the port" >&2
    echo "or reassign this feature to a free port:" >&2
    echo "  bash $SCRIPT_DIR/reassign-port.sh $SLUG" >&2
    exit 1
fi

# Spawn detached. Pass the port explicitly so serve-folder-detached.sh uses
# the value recorded in state.json instead of recomputing cksum%100 (which
# would disagree with the allocator after a collision-probe).
nohup "$SCRIPT_DIR/serve-folder-detached.sh" "$ABS_PATH" "$PORT" > "$LOG_FILE" 2>&1 &
WRAPPER_PID=$!
disown "$WRAPPER_PID" 2>/dev/null || true

# Wait for port bind (max 3s)
for i in 1 2 3 4 5 6; do
    sleep 0.5
    if lsof -ti ":$PORT" >/dev/null 2>&1; then
        break
    fi
done

# Read actual apache master PID from /tmp/apache-<port>.pid
APACHE_PID=""
if [[ -f "/tmp/apache-$PORT.pid" ]]; then
    APACHE_PID=$(cat "/tmp/apache-$PORT.pid" 2>/dev/null || true)
fi

if [[ -z "$APACHE_PID" ]]; then
    # Fall back to lsof
    APACHE_PID=$(lsof -ti ":$PORT" 2>/dev/null | head -1 || true)
fi

if [[ -z "$APACHE_PID" ]]; then
    echo "ERROR: apache failed to bind to :$PORT. Check $LOG_FILE" >&2
    state_set "$SLUG" "apache_running" "false"
    exit 1
fi

state_set "$SLUG" "apache_pid" "$APACHE_PID"
state_set "$SLUG" "apache_running" "true"

echo "Apache started for $SLUG on :$PORT (pid $APACHE_PID)"
echo "Logs: $LOG_FILE"
print_banner "$FULL_URL"
