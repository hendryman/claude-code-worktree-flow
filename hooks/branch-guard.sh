#!/bin/bash
# branch-guard.sh — PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
#
# Hard gate: denies the first file-writing tool call when ALL of these are true:
#   1. Target file is inside a git repo
#   2. Current branch is the repo's base_branch (default "main")
#   3. We're in the MAIN checkout (not a worktree)
#   4. Target file is NOT a meta file (.claude/**, CLAUDE.md, .gitignore, README.md, ~/.claude/**)
#   5. Escape marker /tmp/claude-wtf-plan-exec-ok-<repo-hash> is absent or stale (>5min)
#
# Reason tells the assistant to ASK worktree-vs-base via AskUserQuestion.
# Escape hatch: user says "proceed on <base> anyway" → assistant touches the marker
# and retries. Marker is consumed (deleted) on the pass that honors it.
#
# Reads Claude Code's tool_use JSON on stdin.

set -eu

INPUT=$(cat 2>/dev/null || echo '{}')
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

case "$TOOL_NAME" in
    Edit|Write|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
esac

[[ -z "$FILE_PATH" ]] && exit 0

# Meta-file skips — keep frictionless.
# Sketches/drafts are documented exploration space (animation-template-sketches.md).
case "$FILE_PATH" in
    "$HOME/.claude/"*) exit 0 ;;
    */\.claude/*|*/CLAUDE.md|*/\.gitignore|*/README.md) exit 0 ;;
    */edit/animations/sketch-*/*) exit 0 ;;
    */edit/animations/drafts/*) exit 0 ;;
esac

# Must be inside a git repo (resolve from the target's directory).
TARGET_DIR=$(dirname "$FILE_PATH")
REPO_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0

COMMON_DIR=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
GIT_DIR=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0

case "$COMMON_DIR" in /*) ;; *) COMMON_DIR=$(cd "$REPO_ROOT" && cd "$COMMON_DIR" 2>/dev/null && pwd) ;; esac
case "$GIT_DIR"    in /*) ;; *) GIT_DIR=$(cd "$REPO_ROOT" && cd "$GIT_DIR" 2>/dev/null && pwd) ;; esac
[[ -z "$COMMON_DIR" || -z "$GIT_DIR" ]] && exit 0

# Already inside a worktree → let the edit through.
[[ "$COMMON_DIR" != "$GIT_DIR" ]] && exit 0

# base_branch from per-repo config
BASE_BRANCH="main"
CFG="$REPO_ROOT/.claude/worktree-flow.json"
if [[ -f "$CFG" ]]; then
    b=$(jq -r '.base_branch // "main"' "$CFG" 2>/dev/null || echo "main")
    [[ -n "$b" && "$b" != "null" ]] && BASE_BRANCH="$b"
fi

CURRENT=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
# Non-base branch → deliberate, let through.
[[ "$CURRENT" != "$BASE_BRANCH" ]] && exit 0

md5_of() {
    if command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 -q
    else
        printf '%s' "$1" | md5sum | cut -d' ' -f1
    fi
}
REPO_HASH=$(md5_of "$REPO_ROOT")
ESCAPE="/tmp/claude-wtf-plan-exec-ok-$REPO_HASH"

# Escape hatch: user opted to proceed on base anyway.
# Keep marker alive for the full 5-min TTL so multi-edit sessions don't re-fire.
if [[ -f "$ESCAPE" ]]; then
    mtime=$(stat -f %m "$ESCAPE" 2>/dev/null || stat -c %Y "$ESCAPE" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - ${mtime:-0} ))
    if [[ $age -lt 300 ]]; then
        exit 0
    else
        rm -f "$ESCAPE"
    fi
fi

# Suggest a slug from the newest plan file (used in the AskUserQuestion contract).
SUGGESTED_SLUG="<short-slug>"
PLANS_DIR="$HOME/.claude/plans"
if [[ -d "$PLANS_DIR" ]]; then
    newest=$(ls -t "$PLANS_DIR"/*.md 2>/dev/null | head -1 || true)
    [[ -n "$newest" ]] && SUGGESTED_SLUG=$(basename "$newest" .md)
fi

# Reason text inlines the AskUserQuestion phrasing contract so the plugin does
# not depend on user-installed rule files.
REASON=$(cat <<EOF
On $BASE_BRANCH in main checkout. INVOKE AskUserQuestion NOW (no prose, no paraphrase):

  header   = "Worktree?"
  question = "Implement in a new worktree, or directly on \`$BASE_BRANCH\`?"
  options  = [
    "Worktree"        — create a new worktree, implement isolated.
    "On $BASE_BRANCH" — proceed directly on the main checkout.
  ]

On "Worktree": confirm a short 2-4 word kebab-case slug derived from feature
intent (NOT from a long plan filename). Ask again:

  header   = "Slug?"
  question = "Use \`$SUGGESTED_SLUG\` as the worktree slug?"
  options  = [
    "$SUGGESTED_SLUG" — use this short slug.
    "Use plan filename" — fall back to the plan file basename.
    "Let me type one"   — user supplies one next turn.
  ]

Then run (normalize slug to lowercase kebab-case first):
  bash \${CLAUDE_PLUGIN_ROOT}/scripts/feature-create.sh <slug>
  bash \${CLAUDE_PLUGIN_ROOT}/scripts/apache-start.sh <slug>

All subsequent Edit/Write calls MUST target absolute paths under
<repo>/.worktrees/<slug>/... — cwd cannot change mid-session.

On "On $BASE_BRANCH": touch $ESCAPE  (5-min TTL) then retry this edit.

SKIP RULE: If the user already gave a direct imperative + concrete file path
(e.g. "Remove line 42 of foo.sh"), proceed without re-asking — the explicit
instruction IS the approval.
EOF
)

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'

exit 0
