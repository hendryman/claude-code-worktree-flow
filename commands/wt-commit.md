---
allowed-tools: Bash, Read
description: Commit current worktree with auto-generated message from plan + diff
argument-hint: [optional commit message]
---

Commit the current worktree's changes. Must be run from inside a worktree.

## Process

1. If the user provided a message in `$ARGUMENTS`, skip to step 4 with that message.

2. Run the dry script to collect inputs:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh
   ```
   This prints: SLUG, BRANCH, PLAN FILE (if present), DIFF STAT, FILES list.
   If it prints "Nothing to commit", stop and report to the user.

3. Generate a conventional commit message using these rules:
   - **Type**: `feat` if mostly new files or plan says "add/create"; `fix` if plan says "fix"; `refactor` if mostly modifications + no new capability; `docs` if only docs; `chore` otherwise
   - **Subject** (≤70 chars): one active-voice line summarizing the change, informed by the plan's Context section and the diff
   - **Body** (optional, 1-3 short bullets): only if the change has multiple distinct parts
   - Do NOT reference the task or call out that it's auto-generated

4. Finalize:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh --finalize "<generated-or-user-message>"
   ```

5. Report commit SHA + push result to user.

$ARGUMENTS
