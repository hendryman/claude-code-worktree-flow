#!/bin/bash
# commit.sh [message]
#   Commit current worktree state.
#   - Copies plan file into $plan_commit_dir/<timestamp>_<slug>.md if configured
#   - Stages all changes
#   - Uses provided message, or prints commit inputs to stdout for the assistant
#     to generate a message (the assistant then re-invokes commit.sh with --finalize)
#   - Pushes to origin if auto_push_on_commit is true
#
# Usage:
#   commit.sh                           — print inputs for msg generation (dry)
#   commit.sh --finalize "<message>"    — actually commit and push

set -eu

MODE="dry"
MSG=""
if [[ "${1:-}" == "--finalize" ]]; then
    MODE="finalize"
    MSG="${2:-}"
    [[ -z "$MSG" ]] && { echo "ERROR: --finalize requires a message" >&2; exit 2; }
elif [[ $# -gt 0 ]]; then
    MODE="finalize"
    MSG="$*"
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/../lib/worktree-state.sh"
source "$SCRIPT_DIR/../lib/project-config.sh"

state_init
SLUG=$(state_slug_for_pwd)
[[ -z "$SLUG" ]] && { echo "ERROR: not inside a registered worktree" >&2; exit 2; }

ENTRY=$(state_get "$SLUG")
BRANCH=$(echo "$ENTRY" | jq -r '.branch')
ABS=$(echo "$ENTRY" | jq -r '.abs_path')
PLAN_FILE=$(echo "$ENTRY" | jq -r '.plan_file // empty')

cd "$ABS"

# Clear stale git lock files (any index.lock older than 1 minute is from a
# killed/abandoned operation — real git ops resolve their lock in seconds).
# Find recurses, so this covers MAIN/.git/index.lock AND every worktree's
# .git/worktrees/<slug>/index.lock in one pass. Safe — silent no-op if none.
_MAIN_GITDIR=$(git rev-parse --git-common-dir 2>/dev/null || true)
[[ -n "$_MAIN_GITDIR" ]] && find "$_MAIN_GITDIR" -name "index.lock" -mmin +1 -delete 2>/dev/null || true

CONFIG=$(config_load)
PLAN_COMMIT_DIR=$(echo "$CONFIG" | jq -r '.plan_commit_dir // ""')
COAUTHOR=$(echo "$CONFIG" | jq -r '.commit_coauthor')
AUTO_PUSH=$(echo "$CONFIG" | jq -r '.auto_push_on_commit')

# Copy plan into repo (once, before first commit on this branch)
PLAN_IN_REPO=""
if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" && -n "$PLAN_COMMIT_DIR" ]]; then
    mkdir -p "$ABS/$PLAN_COMMIT_DIR"
    STAMP=$(date +%Y-%m-%d_%H-%M-%S)
    PLAN_IN_REPO="$PLAN_COMMIT_DIR/${STAMP}_${SLUG}.md"
    # Skip if we already copied this plan to this branch
    if ! git log --all --format="%s" | grep -qF "Plan: $PLAN_COMMIT_DIR/"; then
        cp "$PLAN_FILE" "$ABS/$PLAN_IN_REPO"
    else
        PLAN_IN_REPO=""
    fi
fi

git add -A

STATS=$(git diff --cached --stat 2>/dev/null | tail -1)
FILE_CHANGES=$(git diff --cached --name-status 2>/dev/null | head -40)
NUM_FILES=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')

if [[ "$NUM_FILES" == "0" ]]; then
    echo "Nothing to commit."
    exit 0
fi

if [[ "$MODE" == "dry" ]]; then
    # Print everything an assistant needs to generate a commit message
    echo "=== SLUG ==="
    echo "$SLUG"
    echo "=== BRANCH ==="
    echo "$BRANCH"
    if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
        echo "=== PLAN FILE ==="
        cat "$PLAN_FILE"
    fi
    echo "=== DIFF STAT ==="
    echo "$STATS"
    echo "=== FILES ==="
    echo "$FILE_CHANGES"
    echo "=== PLAN IN REPO ==="
    echo "$PLAN_IN_REPO"
    echo "=== END ==="
    exit 0
fi

# Finalize: commit and push
FULL_MSG="$MSG"
if [[ -n "$PLAN_IN_REPO" ]]; then
    FULL_MSG="$FULL_MSG

Plan: $PLAN_IN_REPO"
fi
FULL_MSG="$FULL_MSG

Co-Authored-By: $COAUTHOR"

git commit -m "$FULL_MSG"
COMMIT_SHA=$(git rev-parse --short HEAD)

state_set "$SLUG" "last_commit" "\"$COMMIT_SHA\""

if [[ "$AUTO_PUSH" == "true" ]]; then
    git push -u origin "$BRANCH" 2>&1 | tail -5
fi

echo ""
echo "Committed $COMMIT_SHA on $BRANCH"
