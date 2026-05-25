#!/bin/bash
# feature-abandon.sh <slug>
#   Tear down without merging: kill apache, remove worktree, delete branch, drop from state.

set -eu

SLUG="${1:-}"
[[ -z "$SLUG" ]] && { echo "usage: feature-abandon.sh <slug>" >&2; exit 2; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/../lib/worktree-state.sh"

if ! state_has "$SLUG"; then
    echo "ERROR: feature '$SLUG' not registered" >&2
    exit 2
fi

ENTRY=$(state_get "$SLUG")
BRANCH=$(echo "$ENTRY" | jq -r '.branch')
WT_REL=$(echo "$ENTRY" | jq -r '.path')
WT_ABS=$(echo "$ENTRY" | jq -r '.abs_path')
MAIN_ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)

bash "$SCRIPT_DIR/apache-stop.sh" "$SLUG" || true

if [[ -n "$WT_ABS" && "$WT_ABS" != "null" && -d "$WT_ABS" ]]; then
    bash "$SCRIPT_DIR/htaccess-restore.sh" "$WT_ABS" || true
fi

cd "$MAIN_ROOT"
git worktree remove --force "$WT_REL" 2>&1 | tail -3 || true
rm -rf "$WT_REL" 2>/dev/null || true

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git branch -D "$BRANCH" 2>&1 | tail -1 || true
fi

state_clear_active_slug_everywhere "$SLUG"

state_remove "$SLUG"

# Legacy marker cleanup (harmless no-op if already gone)
REPO_HASH=$(printf '%s' "$MAIN_ROOT" | md5 -q 2>/dev/null || printf '%s' "$MAIN_ROOT" | md5sum | cut -d' ' -f1)
rm -f "/tmp/claude-active-slug-$REPO_HASH"

echo "Abandoned: $SLUG ($BRANCH removed, port freed)"
