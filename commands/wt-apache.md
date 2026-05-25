---
allowed-tools: Bash
description: Start or restart Apache for the current worktree
---

Start (or restart) Apache for the worktree containing the current working directory. Idempotent — safe to call repeatedly.

Run:
```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/apache-start.sh
```

Report the URL and PID back to the user. If apache was already running, say so.

$ARGUMENTS
