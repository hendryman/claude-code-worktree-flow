---
allowed-tools: Bash, Read
description: Create or resume a feature worktree with its own Apache port
---

Create a new feature worktree — or resume an existing one — and (re)start Apache.

## Process

1. Parse `$ARGUMENTS` for the feature slug.
   - If empty, look for a plan file at `~/.claude/plans/<slug>.md` whose slug either (a) has no registered worktree, or (b) has a registered worktree (resume). If exactly one unambiguous match exists, use its basename as the slug (confirm with the user first).
   - Otherwise ask the user for a slug.

2. Run the create-or-resume script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/feature-create.sh <slug>
   ```
   - If the slug is already registered and its worktree dir is intact, the script prints a `Resuming…` banner and exits 0 without touching git.
   - If the slug is new, the script creates the worktree, branch, env copies, and registers state.
   - If the slug is registered but the worktree dir is missing, the script errors out and points at `/wt-abandon <slug>`.

3. Run the apache starter (idempotent — safe on both create and resume):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/apache-start.sh <slug>
   ```

4. Report back to the user with:
   - Whether this was a fresh create or a resume (read from the script's banner)
   - Feature slug, branch, worktree path, port, URL
   - Apache status (just started / already running)
   - Suggestion: `cd .worktrees/<slug>` to start editing there

## Input

$ARGUMENTS
