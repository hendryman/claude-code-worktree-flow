---
allowed-tools: Bash
description: Stop Apache for a feature without removing the worktree
argument-hint: <slug>
---

Pause a feature: kill its Apache process, keep worktree + branch intact. Use when you want to free the port temporarily.

Run:
```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/apache-stop.sh $ARGUMENTS
```

Report whether apache was killed and confirm the worktree is preserved.

$ARGUMENTS
