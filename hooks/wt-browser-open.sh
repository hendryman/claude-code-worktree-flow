#!/bin/bash
# wt-browser-open.sh — Stop hook.
#
# Inside a registered worktree: echo the worktree URL to the transcript and
# open it in Chrome. Chrome open is deduped per (repo, iTerm pane) so we
# don't spawn a new tab every turn — only when the URL actually changes.
#
# Silent when not in a worktree (main checkout stays quiet).

set -eu

# Drain Claude's stdin payload (unused here)
cat >/dev/null 2>&1 || true

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

COMMON_DIR=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$COMMON_DIR" in
    /*) ;;
    *)  COMMON_DIR=$(cd "$REPO_ROOT" && cd "$COMMON_DIR" 2>/dev/null && pwd) || exit 0 ;;
esac
MAIN_ROOT=$(cd "$COMMON_DIR/.." && pwd)

GIT_DIR=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || echo "")
case "$GIT_DIR" in
    /*) ABS_GIT_DIR="$GIT_DIR" ;;
    *)  ABS_GIT_DIR=$(cd "$REPO_ROOT" && cd "$GIT_DIR" 2>/dev/null && pwd) ;;
esac

# Not in a worktree → silent
[[ "$COMMON_DIR" == "$ABS_GIT_DIR" ]] && exit 0

STATE_FILE="$MAIN_ROOT/.worktrees/state.json"
[[ -f "$STATE_FILE" ]] || exit 0

SLUG=$(jq -r --arg p "$REPO_ROOT" '
    .features | to_entries[]
    | select(.value.abs_path == $p)
    | .key' "$STATE_FILE" 2>/dev/null | head -1)
[[ -z "$SLUG" || "$SLUG" == "null" ]] && exit 0

URL=$(jq -r --arg s "$SLUG" '.features[$s].url // empty' "$STATE_FILE" 2>/dev/null)
[[ -z "$URL" ]] && exit 0

# Apply default_url_path override (same logic as apache-start.sh)
CFG="$MAIN_ROOT/.claude/worktree-flow.json"
if [[ -f "$CFG" ]]; then
    URL_PATH=$(jq -r '.default_url_path // empty' "$CFG" 2>/dev/null)
    if [[ -n "$URL_PATH" && "$URL_PATH" != "null" ]]; then
        PORT=$(jq -r --arg s "$SLUG" '.features[$s].port' "$STATE_FILE" 2>/dev/null)
        URL="http://localhost:${PORT}${URL_PATH}"
    fi
fi

md5_of() {
    if command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 -q
    else
        printf '%s' "$1" | md5sum | cut -d' ' -f1
    fi
}

REPO_HASH=$(md5_of "$MAIN_ROOT")
SESSION_ID="${ITERM_SESSION_ID:-${TERM_SESSION_ID:-_default}}"
SESSION_HASH=$(md5_of "$SESSION_ID")
SENTINEL="/tmp/claude-wtf-chrome-${REPO_HASH}-${SESSION_HASH}"
LAST_URL=$(cat "$SENTINEL" 2>/dev/null || echo "")

if [[ "$URL" != "$LAST_URL" ]]; then
    printf '%s' "$URL" > "$SENTINEL"
    ( open -g -a "Google Chrome" "$URL" >/dev/null 2>&1 & ) || true
fi

echo "🌐 $SLUG → $URL"

exit 0
