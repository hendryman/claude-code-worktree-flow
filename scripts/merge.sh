#!/bin/bash
# merge.sh [--force]
#   From inside a worktree: push → PR → merge (merge commit) → teardown.
#   --force: skip confirmation prompts (useful for automation; assistant will confirm first).

set -eu

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/../lib/worktree-state.sh"
source "$SCRIPT_DIR/../lib/project-config.sh"

state_init
SLUG=$(state_slug_for_pwd)
[[ -z "$SLUG" ]] && { echo "ERROR: not inside a registered worktree" >&2; exit 2; }

ENTRY=$(state_get "$SLUG")
BRANCH=$(echo "$ENTRY" | jq -r '.branch')
ABS=$(echo "$ENTRY" | jq -r '.abs_path')
PORT=$(echo "$ENTRY" | jq -r '.port')
WT_REL=$(echo "$ENTRY" | jq -r '.path')

CONFIG=$(config_load)
BASE_BRANCH=$(echo "$CONFIG" | jq -r '.base_branch')
MERGE_STRATEGY=$(echo "$CONFIG" | jq -r '.merge_strategy')
DELETE_BRANCH=$(echo "$CONFIG" | jq -r '.delete_branch_on_merge')

cd "$ABS"

# Clear stale git lock files (any index.lock older than 1 minute is from a
# killed/abandoned operation — real git ops resolve their lock in seconds).
# Find recurses, so this covers MAIN/.git/index.lock AND every worktree's
# .git/worktrees/<slug>/index.lock in one pass. Safe — silent no-op if none.
MAIN_GITDIR=$(git rev-parse --git-common-dir)
find "$MAIN_GITDIR" -name "index.lock" -mmin +1 -delete 2>/dev/null || true

# Verify clean tree
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: uncommitted changes in worktree. Run /wt-commit first." >&2
    exit 2
fi

bash "$SCRIPT_DIR/htaccess-restore.sh" "$ABS" || true

# Ensure branch is pushed
echo "Pushing $BRANCH..."
git push -u origin "$BRANCH" 2>&1 | tail -3

# Find main repo root (for checkout after merge)
MAIN_ROOT=$(cd "$MAIN_GITDIR/.." && pwd)

# Create or fetch PR
PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)
if [[ -z "$PR_NUMBER" ]]; then
    echo "Creating PR..."
    gh pr create --fill --base "$BASE_BRANCH" --head "$BRANCH" 2>&1 | tail -3
    PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number')
fi
echo "PR: #$PR_NUMBER"

# Merge
MERGE_FLAG=""
case "$MERGE_STRATEGY" in
    merge)  MERGE_FLAG="--merge" ;;
    squash) MERGE_FLAG="--squash" ;;
    rebase) MERGE_FLAG="--rebase" ;;
    *)      MERGE_FLAG="--merge" ;;
esac

# NOTE: We deliberately do NOT pass --delete-branch to `gh pr merge`. gh's
# bundled local-branch deletion races against the worktree (still checked out
# on this branch) and fails with "cannot delete branch X used by worktree at
# Y", which exits non-zero AFTER the PR is merged on the remote. We delete
# the local branch ourselves AFTER `git worktree remove` (below), then delete
# the remote branch ourselves at the very end (gated by config).
#
# Run gh pr merge from MAIN_ROOT, NOT from inside the worktree. gh's
# local-side post-merge step does `git checkout <base>`, which fails with
# "fatal: '$BASE_BRANCH' is already used by worktree at ..." when invoked
# from a worktree. Running from MAIN_ROOT means gh sees $BASE_BRANCH as
# already-active and skips the checkout swap entirely.
echo "Merging PR #$PR_NUMBER ($MERGE_STRATEGY)..."
merge_output=$(cd "$MAIN_ROOT" && gh pr merge "$PR_NUMBER" $MERGE_FLAG 2>&1) || {
    # gh may exit non-zero even when the merge itself succeeded (e.g. when
    # an API post-merge step racing with the worktree). Verify state from
    # the source of truth before bailing.
    PR_STATE=$(cd "$MAIN_ROOT" && gh pr view "$PR_NUMBER" --json state --jq .state 2>/dev/null || echo "UNKNOWN")
    if [[ "$PR_STATE" == "MERGED" ]] || echo "$merge_output" | grep -qi "already merged"; then
        echo "PR #$PR_NUMBER is MERGED on the remote (gh exit was non-zero but the merge succeeded); continuing teardown."
    else
        # Real failure. Diagnose by failure mode for an accurate recovery hint.
        echo "$merge_output" | tail -5 >&2
        echo "" >&2
        echo "❌ gh pr merge failed for PR #$PR_NUMBER (current state: $PR_STATE)." >&2
        echo "   Worktree preserved:  $ABS" >&2
        echo "   Branch preserved:    $BRANCH" >&2
        echo "   Apache still running (if started)." >&2
        echo "" >&2
        if echo "$merge_output" | grep -qiE "conflict|not mergeable|merge conflict|need rebase|behind"; then
            echo "   Cause: merge conflict / branch behind base." >&2
            echo "   Recovery:" >&2
            echo "     1. cd $ABS" >&2
            echo "     2. git pull --rebase origin $BASE_BRANCH" >&2
            echo "     3. Resolve conflicts, git add, git rebase --continue" >&2
            echo "     4. git push --force-with-lease" >&2
            echo "     5. Re-run: /wt-merge" >&2
        elif echo "$merge_output" | grep -qiE "checks|status|not ready|required|pending|review"; then
            echo "   Cause: branch protection / required checks / pending review." >&2
            echo "   Recovery: wait for required checks or required reviewers, then re-run /wt-merge." >&2
        elif echo "$merge_output" | grep -qiE "auth|token|credential|401|403"; then
            echo "   Cause: gh auth / GitHub credentials." >&2
            echo "   Recovery: run \`gh auth status\` and re-authenticate, then re-run /wt-merge." >&2
        else
            echo "   Cause unclear — see gh output above." >&2
            echo "   Recovery: investigate, fix, then re-run /wt-merge." >&2
        fi
        exit 2
    fi
}
echo "$merge_output" | tail -5

# Update main checkout (no checkout step — MAIN_ROOT already on $BASE_BRANCH).
echo "Updating main checkout..."
cd "$MAIN_ROOT"
git pull --ff-only origin "$BASE_BRANCH" 2>&1 | tail -3 || {
    echo "WARN: ff-only pull on $BASE_BRANCH failed — local main has unrelated edits or diverged." >&2
    echo "   Remote merge succeeded; sync local main manually with stash + ff-only pull when ready." >&2
}

# Stop apache
bash "$SCRIPT_DIR/apache-stop.sh" "$SLUG" || true

# Remove worktree
echo "Removing worktree $WT_REL..."
git worktree remove --force "$WT_REL" 2>&1 | tail -3 || true
rm -rf "$WT_REL" 2>/dev/null || true

# Delete local branch (now unblocked — worktree was removed above).
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git branch -D "$BRANCH" 2>&1 | tail -1 || true
fi

# Delete remote branch (gated by config). Idempotent: GitHub's "auto-delete
# head branches" repo setting may have already deleted it, in which case
# `git push origin --delete` is a no-op that exits non-zero — tolerated.
if [[ "$DELETE_BRANCH" == "true" ]]; then
    git push origin --delete "$BRANCH" 2>&1 | tail -2 || true
fi

# Clear the merged slug from any session bucket before removing the feature.
state_clear_active_slug_everywhere "$SLUG"

# Remove from state
state_remove "$SLUG"

# Legacy marker cleanup (harmless no-op if already gone)
REPO_HASH=$(printf '%s' "$MAIN_ROOT" | md5 -q 2>/dev/null || printf '%s' "$MAIN_ROOT" | md5sum | cut -d' ' -f1)
rm -f "/tmp/claude-active-slug-$REPO_HASH"

echo ""
echo "═══════════════════════════════════════════"
echo "  Merged:   $SLUG → $BASE_BRANCH"
echo "  PR:       #$PR_NUMBER"
echo "  Port:     $PORT (freed)"
echo "═══════════════════════════════════════════"
