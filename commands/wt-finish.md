---
allowed-tools: Bash, Read
description: Commit any uncommitted work, then PR + merge the current worktree
argument-hint: [optional commit message]
---

From inside a worktree: auto-commit any pending work (via the `/wt-commit` flow), then run the full `/wt-merge` flow (push → PR → merge → teardown). One-shot "ship it" for when you're done.

## Process

1. Determine if the worktree has uncommitted changes:
   ```
   git status --porcelain
   ```
   Also capture the slug for reporting by running the commit-dry script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh
   ```
   If this prints `ERROR: not inside a registered worktree`, stop and tell the user to run this from inside a worktree.

2. **If there are uncommitted changes**, follow the `/wt-commit` process:
   - If `$ARGUMENTS` is non-empty, use it verbatim as the commit message.
   - Otherwise, generate a conventional commit message from the dry-run output captured in step 1 using the rules in `/wt-commit`:
     - Type: `feat` if mostly new files or plan says "add/create"; `fix` if plan says "fix"; `refactor` if modifications + no new capability; `docs` if only docs; `chore` otherwise
     - Subject ≤70 chars, active voice, informed by the plan's Context section and the diff
     - Body optional (1-3 short bullets) only if the change has multiple distinct parts
     - Do NOT reference the task or call out that it's auto-generated
   - Finalize:
     ```
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh --finalize "<message>"
     ```

   **If the tree is already clean**, skip straight to step 3.

3. Run the merge:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh
   ```

4. Report: commit SHA (if a commit happened), PR number, merge SHA, teardown confirmation.

$ARGUMENTS
