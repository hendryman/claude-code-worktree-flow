#!/bin/bash
# commit-merge-reminder.sh — Stop hook.
#
# Emits a /wt-commit or /wt-merge reminder after turns that changed git state.
# Silent when state unchanged since last reminder — this naturally filters out
# plan-mode and read-only turns without needing to parse Claude's session JSON.
#
# Matrix:
#   In worktree + dirty                       → 💾 N uncommitted in <slug>. /wt-commit
#   In worktree + clean + ahead of base ≥ 1   → 🚀 <slug> is N ahead of <base>. /wt-merge
#   Main checkout + on base_branch + dirty    → 💾 N uncommitted on <base>. /wt-create <slug>
#   Otherwise                                 → silent

set -eu

# Drain Claude's stdin payload (we don't need it)
cat >/dev/null 2>&1 || true

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

COMMON_DIR=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$COMMON_DIR" in
    /*) ;;
    *)  COMMON_DIR=$(cd "$REPO_ROOT" && cd "$COMMON_DIR" 2>/dev/null && pwd) || exit 0 ;;
esac
MAIN_ROOT=$(cd "$COMMON_DIR/.." && pwd)

md5_of() {
    if command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 -q
    else
        printf '%s' "$1" | md5sum | cut -d' ' -f1
    fi
}

# Fingerprint = HEAD + porcelain status hash. Any tree mutation or new commit
# changes this. Plan mode + read-only turns leave it unchanged.
HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "-")
STATUS_RAW=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || echo "")
STATUS_HASH=$(md5_of "$STATUS_RAW")
FP="${HEAD_SHA}-${STATUS_HASH}"

REPO_HASH=$(md5_of "$REPO_ROOT")
LAST_FILE="/tmp/claude-wtf-laststate-$REPO_HASH"
LAST=$(cat "$LAST_FILE" 2>/dev/null || echo "")

if [[ "$FP" == "$LAST" ]]; then
    exit 0
fi
printf '%s' "$FP" > "$LAST_FILE"

# Determine base_branch from project config
BASE_BRANCH="main"
CFG="$MAIN_ROOT/.claude/worktree-flow.json"
if [[ -f "$CFG" ]]; then
    b=$(jq -r '.base_branch // "main"' "$CFG" 2>/dev/null || echo "main")
    [[ -n "$b" && "$b" != "null" ]] && BASE_BRANCH="$b"
fi

# In a worktree?
IN_WORKTREE=0
GIT_DIR=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || echo "")
case "$GIT_DIR" in
    /*) ABS_GIT_DIR="$GIT_DIR" ;;
    *)  ABS_GIT_DIR=$(cd "$REPO_ROOT" && cd "$GIT_DIR" 2>/dev/null && pwd) ;;
esac
[[ "$COMMON_DIR" != "$ABS_GIT_DIR" ]] && IN_WORKTREE=1

SLUG=""
STATE_FILE="$MAIN_ROOT/.worktrees/state.json"
if [[ $IN_WORKTREE -eq 1 && -f "$STATE_FILE" ]]; then
    SLUG=$(jq -r --arg p "$REPO_ROOT" '
        .features | to_entries[]
        | select(.value.abs_path == $p)
        | .key' "$STATE_FILE" 2>/dev/null | head -1)
    [[ "$SLUG" == "null" ]] && SLUG=""
fi

DIRTY_COUNT=$(printf '%s\n' "$STATUS_RAW" | awk 'NF' | wc -l | tr -d ' ')

AHEAD=0
if git -C "$REPO_ROOT" rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    AHEAD=$(git -C "$REPO_ROOT" rev-list --count "$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)
fi

if [[ $IN_WORKTREE -eq 1 ]]; then
    if [[ $DIRTY_COUNT -gt 0 ]]; then
        echo "💾 $DIRTY_COUNT uncommitted in ${SLUG:-worktree} → /wt-commit (stay) · /merge (commit + PR + merge + cleanup)"
    elif [[ $AHEAD -gt 0 ]]; then
        echo "🚀 ${SLUG:-worktree} is $AHEAD ahead of $BASE_BRANCH → /wt-merge (PR + merge + teardown)"
    fi
else
    CURRENT=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [[ "$CURRENT" == "$BASE_BRANCH" && $DIRTY_COUNT -gt 0 ]]; then
        echo "💾 $DIRTY_COUNT uncommitted on $BASE_BRANCH → /wt-create <slug> (isolate into worktree w/ own Apache port)"
    fi
fi

exit 0
