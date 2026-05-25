#!/usr/bin/env bash
# orphans-list.sh — detect inconsistencies between .worktrees/ and state.json.
#
# Two kinds of orphans:
#   1. Filesystem orphans: .worktrees/<slug>/ exists but no entry in state.json.
#      (Typically: manual `git worktree add`, or feature-create.sh crashed
#       mid-registration.)
#   2. State orphans: state.json has an entry but .worktrees/<slug>/ is missing.
#      (Typically: someone `rm -rf`'d the worktree dir without /wt-abandon.)
#
# Read-only. Suggests recovery commands but does not execute them.

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
    echo "No state.json for this repo."
    exit 0
fi

state_dir=$(dirname "$state_path")
repo_root=$(dirname "$state_dir")

# Kind 1: filesystem orphans
fs_orphans=()
if [[ -d "$state_dir" ]]; then
    while IFS= read -r -d '' d; do
        slug=$(basename "$d")
        # Skip non-worktree items (archive/, tmp files, etc.)
        [[ "$slug" == "archive" ]] && continue
        [[ "$slug" =~ ^state\.json ]] && continue
        [[ -d "$d/.git" || -f "$d/.git" ]] || continue
        if ! state_get "$slug" >/dev/null 2>&1; then
            fs_orphans+=("$slug")
        elif [[ -z "$(state_get "$slug")" ]]; then
            fs_orphans+=("$slug")
        fi
    done < <(find "$state_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

# Kind 2: state orphans
state_orphans=()
while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue
    entry=$(state_get "$slug")
    abs=$(echo "$entry" | jq -r '.abs_path // empty')
    if [[ -n "$abs" && ! -d "$abs" ]]; then
        state_orphans+=("$slug")
    fi
done < <(state_slugs 2>/dev/null || true)

# Report
echo "Worktree orphans for: $repo_root"
echo ""

if [[ "${#fs_orphans[@]}" -eq 0 ]]; then
    echo "✓ No filesystem orphans (all .worktrees/ dirs registered in state.json)"
else
    echo "📁 Filesystem orphans (worktree exists, no state.json entry):"
    for s in "${fs_orphans[@]}"; do
        dir="$state_dir/$s"
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        echo "  • $s  (branch: $branch, uncommitted: $dirty)"
        echo "     → Inspect: (cd $dir && git status)"
        echo "     → Adopt:   bash $SCRIPT_DIR/feature-create.sh $s"
        echo "     → Remove:  git worktree remove --force $dir"
    done
fi

echo ""

if [[ "${#state_orphans[@]}" -eq 0 ]]; then
    echo "✓ No state orphans (all state.json entries have matching worktree dirs)"
else
    echo "📋 State orphans (state.json entry, worktree dir missing):"
    for s in "${state_orphans[@]}"; do
        echo "  • $s"
        echo "     → Clear: bash $SCRIPT_DIR/feature-abandon.sh $s"
    done
fi
