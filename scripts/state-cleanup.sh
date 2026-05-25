#!/usr/bin/env bash
# state-cleanup.sh — explicit janitor for .worktrees/ state.
#
# Runs the same cleanup that session-start.sh does automatically, but as a
# user-invokable command (/wt-state-cleanup). Useful when you notice cruft
# and want to flush it without opening a new Claude session.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worktree-state.sh"

if ! git rev-parse --git-common-dir >/dev/null 2>&1; then
    echo "ERROR: not in a git repository" >&2
    exit 2
fi

state_path=$(state_file 2>/dev/null || true)
if [[ -z "$state_path" || ! -f "$state_path" ]]; then
    echo "No state.json for this repo. Nothing to clean."
    exit 0
fi

state_dir=$(dirname "$state_path")
echo "State dir: $state_dir"

# 1. GC orphan state.json.tmp.* (anything older than 60 minutes is leftover
#    from a failed jq+mv; live operations complete in milliseconds).
orphans=$(find "$state_dir" -maxdepth 1 -name 'state.json.tmp.*' -mmin +60 2>/dev/null | wc -l | tr -d ' ')
if [[ "$orphans" -gt 0 ]]; then
    find "$state_dir" -maxdepth 1 -name 'state.json.tmp.*' -mmin +60 -delete 2>/dev/null || true
    echo "🧹 Removed $orphans orphan state.json.tmp.* file(s)"
else
    echo "✓ No orphan state.json.tmp.* files"
fi

# 2. Reconcile features (flag missing worktree dirs as stale, GC session buckets).
state_reconcile_features 2>/dev/null || true
echo "✓ Reconciled feature entries"

# 3. Reconcile Apache PIDs (mark dead PIDs as apache_running=false).
state_reconcile_apache 2>/dev/null || true
echo "✓ Reconciled Apache PIDs"

# 4. Archive old plans (delegated).
if [[ -x "$SCRIPT_DIR/archive-plans.sh" ]]; then
    bash "$SCRIPT_DIR/archive-plans.sh"
fi

echo ""
echo "Done."
