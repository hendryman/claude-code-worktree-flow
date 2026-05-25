#!/bin/bash
# session-start.sh — runs on each Claude Code SessionStart.
#
# Responsibilities:
#   1. On source="startup" (fresh Claude session): clear THIS pane's
#      active-slug bucket so the session begins with a blank worktree
#      pointer. The "current worktree" is a Claude-session property; it
#      must not leak from a prior session that shared the same iTerm pane.
#      source="resume"|"clear"|"compact" preserve the bucket — the session
#      is continuing, not starting.
#   2. Reconcile state.json: flag features whose worktree dir is gone, GC
#      stale session buckets (per-iterm-pane active_slug pointers).
#   3. GC legacy /tmp/claude-active-slug-* + /tmp/claude-session-*-started
#      files older than 7 days.
#
# Silent on success (hooks shouldn't spam session output).

set -eu

INPUT=$(cat 2>/dev/null || true)
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worktree-state.sh" 2>/dev/null || exit 0

# Reconcile state for the repo that spawned this Claude session, if any.
# cwd when hooks fire is the session's project directory.
if git rev-parse --git-common-dir >/dev/null 2>&1; then
    state_file_path=$(state_file 2>/dev/null || true)
    if [[ -n "$state_file_path" && -f "$state_file_path" ]]; then
        # Fresh session → drop this pane's active-slug pointer. Must run
        # BEFORE reconcile so the empty bucket doesn't get GC'd as "stale"
        # and then silently repopulated.
        if [[ "$SOURCE" == "startup" ]]; then
            state_clear_active_slug 2>/dev/null || true
        fi
        state_reconcile_features 2>/dev/null || true
        state_reconcile_apache 2>/dev/null || true

        # GC orphan state.json.tmp.* files. These are leftover from
        # `jq ... > $tmp && mv $tmp $f` pairs in worktree-state.sh when the
        # mv never ran (process died, perms, Dropbox lock). Live operations
        # complete in milliseconds, so anything older than 60 minutes is
        # definitely orphan.
        state_dir=$(dirname "$state_file_path")
        find "$state_dir" -maxdepth 1 -name 'state.json.tmp.*' -mmin +60 -delete 2>/dev/null || true
    fi
fi

# GC /tmp markers older than 7 days (legacy + session-started). -mtime +7 on
# macOS is "modified more than 7*24h ago". find errors are silenced.
find /tmp -maxdepth 1 -name 'claude-active-slug-*' -mtime +7 -delete 2>/dev/null || true
find /tmp -maxdepth 1 -name 'claude-session-*-started' -mtime +7 -delete 2>/dev/null || true

# Archive old plans (>14 days) in the background so session startup never
# blocks on filesystem I/O. Non-fatal; silently continues on any error.
if [[ -x "$SCRIPT_DIR/archive-plans.sh" ]]; then
    ( bash "$SCRIPT_DIR/archive-plans.sh" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

exit 0
