#!/bin/bash
# branch-guard.sh — PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
#
# Gates file writes into the MAIN checkout of a repo that is on its base_branch
# (default "main"). Lets the write through when:
#   • the target is not in a git repo, is inside a worktree, or the repo is on
#     another branch
#   • the target is a meta file (.claude/**, CLAUDE.md, .gitignore, README.md,
#     ~/.claude/**)
#   • the escape marker /tmp/claude-wtf-plan-exec-ok-<repo-hash> is fresh
#     (<5 min): the user chose "On <base>"
#   • this Claude session already works in a worktree of the repo and the
#     target is gitignored, so it can never land in a commit on <base>
#
# Otherwise it denies:
#   • session already works in a worktree of this repo → the reason names the
#     same file inside that worktree. No question.
#   • no worktree of this repo yet → the reason tells the assistant to ASK
#     worktree-vs-base via AskUserQuestion. Each repo is asked on its own.
#
# Reads Claude Code's tool_use JSON on stdin.

set -eu

INPUT=$(cat 2>/dev/null || echo '{}')
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
PLUGIN_ROOT=$(cd "$(dirname "$0")/.." && pwd)

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

deny() {
    jq -n --arg reason "$1" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
}

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

# shellcheck source=../lib/worktree-state.sh
source "$PLUGIN_ROOT/lib/worktree-state.sh"
SESSION_WT=$(state_session_worktree "$REPO_ROOT/.worktrees/state.json" "$SESSION_ID" "${CLAUDE_CODE_SESSION_ID:-}")
if [[ -n "$SESSION_WT" ]]; then
    WT_SLUG=${SESSION_WT%%$'\t'*}
    WT_ABS=${SESSION_WT#*$'\t'}
    FILE_NAME=$(basename "$FILE_PATH")
    git -C "$TARGET_DIR" check-ignore -q -- "$FILE_NAME" 2>/dev/null && exit 0
    REL_PATH="$(git -C "$TARGET_DIR" rev-parse --show-prefix 2>/dev/null || true)$FILE_NAME"
    deny "$(cat <<EOF
This session already works in worktree \`$WT_SLUG\` of this repo. Do not ask
Worktree vs $BASE_BRANCH. Make this change in the worktree copy instead:

  $WT_ABS/$REL_PATH

Read that file first (it can differ from the main checkout), then retry there.
All further edits in this repo go under $WT_ABS/.
EOF
)"
fi

REPO_NAME=$(basename "$REPO_ROOT")

# Reason text inlines the AskUserQuestion phrasing contract so the plugin does
# not depend on user-installed rule files.
deny "$(cat <<EOF
On $BASE_BRANCH in main checkout of $REPO_NAME. INVOKE AskUserQuestion NOW with this ONE
question (no prose, no paraphrase). It is the only worktree question: never ask a
separate slug question, before or after it.

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
(5-min TTL) then retry this edit.

On a slug, suggested or typed (normalize to lowercase kebab-case), run:
  (cd "$REPO_ROOT" && bash "$PLUGIN_ROOT/scripts/feature-create.sh" <slug>)
  (cd "$REPO_ROOT" && bash "$PLUGIN_ROOT/scripts/apache-start.sh" <slug>)
A typed slug that names an existing worktree resumes it.

All subsequent Edit/Write calls for this repo MUST target absolute paths under
$REPO_ROOT/.worktrees/<slug>/... — cwd cannot change mid-session. The gate
does not ask again for this repo while the session works in that worktree.

SKIP RULE: If the user already gave a direct imperative + concrete file path
(e.g. "Remove line 42 of foo.sh"), proceed without re-asking — the explicit
instruction IS the approval.
EOF
)"
