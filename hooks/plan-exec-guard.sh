#!/bin/bash
# plan-exec-guard.sh — PreToolUse hook for ExitPlanMode.
#
# Blocks the first ExitPlanMode attempt when the session is on base_branch in
# the main checkout (no worktree yet). Instructs the assistant to ASK the user
# whether to create an isolated worktree first via /wt-create.
#
# Escape hatch: if the user says "proceed on base anyway", the assistant can
# `touch /tmp/claude-wtf-plan-exec-ok-<repo-hash>` and retry — the marker
# (TTL 5min) is honored once then cleared.
#
# Exits 0 (pass) when:
#   • Not in a git repo
#   • Already inside a worktree
#   • On a non-base branch
#   • Escape marker present and fresh

set -eu

INPUT=$(cat 2>/dev/null || echo '{}')
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
[[ "$TOOL" != "ExitPlanMode" ]] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

COMMON_DIR=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
GIT_DIR=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0

case "$COMMON_DIR" in /*) ;; *) COMMON_DIR=$(cd "$REPO_ROOT" && cd "$COMMON_DIR" 2>/dev/null && pwd) ;; esac
case "$GIT_DIR"    in /*) ;; *) GIT_DIR=$(cd "$REPO_ROOT" && cd "$GIT_DIR" 2>/dev/null && pwd) ;; esac
[[ -z "$COMMON_DIR" || -z "$GIT_DIR" ]] && exit 0

# Already inside a worktree → let ExitPlanMode through.
[[ "$COMMON_DIR" != "$GIT_DIR" ]] && exit 0

# base_branch from per-repo config
BASE_BRANCH="main"
CFG="$REPO_ROOT/.claude/worktree-flow.json"
if [[ -f "$CFG" ]]; then
    b=$(jq -r '.base_branch // "main"' "$CFG" 2>/dev/null || echo "main")
    [[ -n "$b" && "$b" != "null" ]] && BASE_BRANCH="$b"
fi

CURRENT=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
# If we're on a non-base branch, the user is already doing something deliberate — don't interfere.
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

# Escape hatch: user explicitly opted to proceed on $BASE_BRANCH
if [[ -f "$ESCAPE" ]]; then
    mtime=$(stat -f %m "$ESCAPE" 2>/dev/null || stat -c %Y "$ESCAPE" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - ${mtime:-0} ))
    rm -f "$ESCAPE"
    [[ $age -lt 300 ]] && exit 0
fi

# Suggest a slug from the newest plan file
SUGGESTED_SLUG="<slug>"
PLANS_DIR="$HOME/.claude/plans"
if [[ -d "$PLANS_DIR" ]]; then
    newest=$(ls -t "$PLANS_DIR"/*.md 2>/dev/null | head -1 || true)
    if [[ -n "$newest" ]]; then
        SUGGESTED_SLUG=$(basename "$newest" .md)
    fi
fi

# Reason text inlines the AskUserQuestion phrasing contract so the plugin does
# not depend on user-installed rule files.
REASON=$(cat <<EOF
Exiting plan on $BASE_BRANCH in main checkout. INVOKE AskUserQuestion NOW
(no prose, no paraphrase):

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

Implementation must then use absolute paths under <repo>/.worktrees/<slug>/...

On "On $BASE_BRANCH": touch $ESCAPE  (5-min TTL) then retry ExitPlanMode.

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
