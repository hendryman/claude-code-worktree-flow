#!/bin/bash
# plan-exec-guard.sh — PreToolUse hook for ExitPlanMode.
#
# Blocks the first ExitPlanMode attempt when the session is on base_branch in
# the main checkout and has no worktree of this repo yet. Instructs the
# assistant to ASK the user whether to create an isolated worktree first.
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
#   • This Claude session already works in a worktree of the repo (cwd stays
#     in the main checkout after /wt-create). Passes with a note naming it.

set -eu

INPUT=$(cat 2>/dev/null || echo '{}')
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
[[ "$TOOL" != "ExitPlanMode" ]] && exit 0
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
PLUGIN_ROOT=$(cd "$(dirname "$0")/.." && pwd)

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

# shellcheck source=../lib/worktree-state.sh
source "$PLUGIN_ROOT/lib/worktree-state.sh"
SESSION_WT=$(state_session_worktree "$REPO_ROOT/.worktrees/state.json" "$SESSION_ID" "${CLAUDE_CODE_SESSION_ID:-}")
if [[ -n "$SESSION_WT" ]]; then
    WT_SLUG=${SESSION_WT%%$'\t'*}
    WT_ABS=${SESSION_WT#*$'\t'}
    jq -n --arg ctx "This session already works in worktree \`$WT_SLUG\` of this repo. Do not ask Worktree vs $BASE_BRANCH. Implement the plan there, with absolute paths under $WT_ABS/." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: $ctx
      }
    }'
    exit 0
fi

REPO_NAME=$(basename "$REPO_ROOT")

# Reason text inlines the AskUserQuestion phrasing contract so the plugin does
# not depend on user-installed rule files.
REASON=$(cat <<EOF
Exiting plan on $BASE_BRANCH in main checkout of $REPO_NAME. INVOKE AskUserQuestion NOW
with this ONE question (no prose, no paraphrase). It is the only worktree question:
never ask a separate slug question, before or after it.

  header   = "Worktree"
  question = "Worktree slug for \`$REPO_NAME\`, or stay on \`$BASE_BRANCH\`?"
  options  = [   (exactly these two, in this order)
    "Use $BASE_BRANCH" — proceed directly on the main checkout.
    "<slug>"     — a short 2-4 word kebab-case slug YOU derive from the feature
                   intent; its description says what the worktree is for.
  ]

The question's built-in free-text field is where the user types their own slug.
Do not add a "Let me type one" or a plan-filename option.

On "Use $BASE_BRANCH" (or "$BASE_BRANCH" typed in the field): touch $ESCAPE
(5-min TTL) then retry ExitPlanMode.

On a slug, suggested or typed (normalize to lowercase kebab-case), run:
  (cd "$REPO_ROOT" && bash "$PLUGIN_ROOT/scripts/feature-create.sh" <slug>)
  (cd "$REPO_ROOT" && bash "$PLUGIN_ROOT/scripts/apache-start.sh" <slug>)
A typed slug that names an existing worktree resumes it.

Implementation must then use absolute paths under $REPO_ROOT/.worktrees/<slug>/...
The gate does not ask again for this repo while the session works in that worktree.

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
