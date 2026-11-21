# worktree-flow

Parallel-feature development for solo macOS PHP/web devs: one git worktree + one Apache port per feature, previewable in the browser, torn down automatically on merge.

## What it does

- `/wt-create <slug>` — spawns `.worktrees/<slug>/` on branch `claude/<slug>` off `main`, starts Apache on a deterministic collision-probed port (`8100–8199`), reports `http://localhost:<port>/`.
- `/wt-features` — lists all active features with status, port, URL, uncommitted count.
- `/wt-apache` — starts/restarts Apache for the worktree you're `cd`'d into.
- `/wt-commit [msg]` — auto-generates a conventional commit message from the plan file + diff, commits, pushes.
- `/wt-finish [msg]` — one-shot ship-it: commits any pending work, then `/wt-merge`.
- `/wt-merge` — pushes, opens PR, merges (merge commit by default), tears down worktree, kills Apache, removes branch.
- `/wt-stop <slug>` / `/wt-resume <slug>` — pause/resume Apache without removing the worktree.
- `/wt-abandon <slug>` — throw away: kill, remove, delete branch. No PR.
- `/wt-orphans` — detect `.worktrees/` ↔ `state.json` inconsistencies (read-only).
- `/wt-state-cleanup` — explicit janitor: GC temp files, reconcile features + Apache PIDs, archive old plans.

## Why it exists

Solo devs lose track of git. Feature branches accumulate, commits pile up unpushed, working trees fill with months-old cruft. This plugin eliminates the ceremony: each feature is a real folder in Finder with its own port. The URL is what you work against. Git branches are a byproduct.

## Requirements (hard)

- **macOS** (Apple Silicon or Intel). Linux/Windows are not supported.
- **Homebrew Apache + PHP**: `brew install httpd php`
- **`jq`**: `brew install jq`
- **`gh`** CLI, authenticated against GitHub: `brew install gh && gh auth login`

The plugin auto-detects Homebrew Apache at `/opt/homebrew/opt/httpd` (Apple Silicon) or `/usr/local/opt/httpd` (Intel). For a custom Apache install, set:

```bash
export WTF_HTTPD_ROOT=/path/to/httpd          # required
export WTF_HTTPD_MIME=/path/to/mime.types     # optional, auto-derived
export WTF_HTTPD_PHP_MODULE=/path/to/libphp.so # optional, auto-derived
```

## Install

```
/plugin marketplace add <marketplace-url>
/plugin install worktree-flow
```

Then restart Claude Code (plugins load at startup). The plugin's hooks (branch-guard, plan-exec-guard, Stop-event commit/browser reminders, SessionStart janitor) are registered automatically via the plugin manifest.

### Optional: enable the statusline indicator

`statusLine` is not a valid plugin manifest field per Claude Code's plugin schema — it must live in `~/.claude/settings.json`. Add manually after install:

```json
"statusLine": {
  "type": "command",
  "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/statusline-combined.sh"
}
```

Replace `${CLAUDE_PLUGIN_ROOT}` with the literal cache path
(`~/.claude/plugins/cache/<marketplace>/worktree-flow/<version>/`) — `settings.json`
does not expand plugin env vars.

The statusline composes with `claude-hud` if you have that plugin installed; otherwise it shows just the worktree segment.

## Per-project config

Create `./.claude/worktree-flow.json` in each repo where you want to use the plugin:

```json
{
  "base_branch": "main",
  "branch_prefix": "claude",
  "env_files": ["index.settings.json", ".env", "data.json"],
  "runtime_symlinks": ["node_modules", "vendor"],
  "plan_commit_dir": "edit/commits",
  "merge_strategy": "merge",
  "commit_coauthor": "Claude <noreply@anthropic.com>",
  "auto_push_on_commit": true,
  "delete_branch_on_merge": true,
  "default_url_path": "/"
}
```

All fields are optional; defaults are in `lib/project-config.sh`.

- **`env_files`**: gitignored files copied from main checkout into each new worktree (API keys, generated data, etc.)
- **`runtime_symlinks`**: large dirs symlinked rather than copied (e.g. `node_modules`).
- **`plan_commit_dir`**: where plan files get committed alongside the work. Empty string = disabled.
- **`merge_strategy`**: `merge` (default, preserves branch structure) / `squash` / `rebase`
- **`default_url_path`**: appended to the worktree URL in the Stop-hook browser banner (e.g. `/admin`).

## State file

Each repo gets `.worktrees/state.json` (gitignored — and `xattr`-marked Dropbox-ignored on Dropbox-hosted repos) tracking:

```json
{
  "features": {
    "<slug>": {
      "branch": "claude/<slug>",
      "path": ".worktrees/<slug>",
      "abs_path": "/absolute/path",
      "port": 8142,
      "url": "http://localhost:8142/",
      "apache_pid": 31284,
      "apache_running": true,
      "base_ref": "main",
      "base_sha": "abc1234",
      "plan_file": "~/.claude/plans/<slug>.md",
      "created": "2026-04-17T15:30:00Z",
      "last_commit": "def5678",
      "status": "active"
    }
  },
  "sessions": {
    "<terminal-session-id>": {
      "active_slug": "<slug>",
      "last_seen": "2026-05-25T10:00:00Z"
    },
    "claude:<claude-session-id>": {
      "active_slug": "<slug>",
      "last_seen": "2026-05-25T10:00:00Z"
    }
  },
  "port_range": [8100, 8199],
  "schema_version": 1
}
```

## The worktree-vs-base gate

The plugin's `branch-guard` (PreToolUse `Edit|Write|MultiEdit|NotebookEdit`) and `plan-exec-guard` (PreToolUse `ExitPlanMode`) hooks intercept work that would otherwise land on `main` in the main checkout. The hook denies the action with a `reason` that instructs Claude to ask the user via `AskUserQuestion`:

- **Worktree** → run `feature-create.sh` + `apache-start.sh` for an isolated worktree
- **On `<base>`** → `touch /tmp/claude-wtf-plan-exec-ok-<repo-hash>` (5-min TTL) and retry

Once the session works in a worktree of the repo, the gate stops asking for that repo. This covers a worktree made or resumed by `/wt-create`, by `/wt-resume`, or by a "Worktree" answer to the gate. The session's cwd stays in the main checkout, so:

- `ExitPlanMode` passes, with a note that names the worktree.
- An edit aimed at the main checkout is denied, and the reason gives the same file's path inside the worktree. There is no question.
- Gitignored files in the main checkout pass, because they never reach a commit.

Each repo is gated on its own. If the session edits a second repo that has no worktree, the gate asks there once, and a "Worktree" answer covers that repo from then on. The session is recognised by its Claude session id, which survives `/resume` in another pane, and by its terminal pane, which survives `/clear`. Both pointers live in `sessions` in `state.json`.

Meta-file edits (`.claude/**`, `CLAUDE.md`, `.gitignore`, `README.md`, anything under `~/.claude/**`) skip the gate.

The AskUserQuestion phrasing contract is self-contained in the hook output — no user-side rule files are needed.

## Stop-event reminders

Two hooks fire on every assistant Stop:

- `commit-merge-reminder.sh` — detects git state changes (HEAD movement, dirty status) since the last turn and emits `/wt-commit` or `/wt-merge` reminders in transcript. Fingerprint-deduped per `/tmp/claude-wtf-laststate-<repo-hash>`.
- `wt-browser-open.sh` — echoes the worktree URL to transcript and opens it in Chrome (deduped per repo + terminal-session combo via `/tmp/claude-wtf-chrome-<repo-hash>-<session-hash>`).

## Apache internals

`scripts/serve-folder-detached.sh`:
- Generates `/tmp/apache-<port>.conf` with `DocumentRoot` = worktree path
- Full PHP 8.5 module, `.htaccess` support, `mod_rewrite`, auth modules
- PID at `/tmp/apache-<port>.pid`, logs at `/tmp/apache-<port>.log`
- Same-folder restart is idempotent; different-folder collision aborts loudly so callers (`apache-start.sh`) must explicitly resolve

## `.htaccess` auth bypass

If the repo has a root `.htaccess` with HTTP Basic auth (`AuthType`, `AuthUserFile`, `Require user/valid-user/group`), `/wt-create` auto-disables it in the worktree so the per-feature Apache serves without credential prompts:

- `scripts/htaccess-disable-auth.sh` runs at worktree create/resume. Copies `.htaccess` → `.htaccess-backup`, comments auth directives with a `#WTAUTH#` prefix, injects `Require all granted` into every `<RequireAny>` block, marks `--skip-worktree`, adds `.htaccess-backup` to `$GIT_COMMON_DIR/info/exclude`.
- `scripts/htaccess-restore.sh` runs at `/wt-merge` (before push) and `/wt-abandon`. Clears skip-worktree, restores from backup, strips the exclude line.

Repos without auth in `.htaccess` are untouched. Non-auth directives (`ErrorDocument`, `Options`, `RedirectMatch`, `<IfModule>`, security headers, rewrite rules) are preserved.

**Side effect**: edits to `.htaccess` inside a worktree are invisible to git because of `--skip-worktree`. To edit `.htaccess` intentionally, edit `.htaccess-backup` (it becomes the committed version on `/wt-merge`) or `git update-index --no-skip-worktree .htaccess` first.

## Dropbox safety

If your repo is inside a Dropbox folder, `lib/worktree-state.sh` applies `xattr -w com.dropbox.ignored 1 .worktrees` on first use to prevent Dropbox from syncing `.git/worktrees/*` metadata between machines.

## Gotchas

- **Port collisions**: 100 slots in 8100–8199. Hash-based allocation with linear probing — collisions are auto-resolved but you may end up on an unexpected port.
- **Uncommitted changes on merge**: `/wt-merge` refuses. Run `/wt-commit` first (or use `/wt-finish` which does both).
- **PR merge failure**: if `gh pr merge` fails, `merge.sh` exits non-zero and preserves worktree, branch, Apache, and state. See recovery below.
- **Base branch must exist locally**: the plugin assumes `main` (or configured `base_branch`) exists locally. Does not auto-fetch origin.
- **gh auth required**: `gh auth status` must show authenticated before `/wt-merge`.

## Recovering from a failed merge

When `gh pr merge` fails (conflicts with `main`, required status check unresolved, permission denied, network), `merge.sh` prints the recovery path and exits without teardown.

Typical recovery for a conflict:

```bash
cd .worktrees/<slug>/
git fetch origin
git rebase origin/main         # resolve conflicts in editor
git add <resolved files>
git rebase --continue
git push --force-with-lease
/wt-merge                      # retry
```

For a required-check failure, push the fix (or wait for the check) and re-run `/wt-merge`. For auth/network issues, fix and re-run — no state reconciliation needed.

To bail entirely: `/wt-abandon <slug>` throws away worktree + branch.

## Uninstall

```
/plugin remove worktree-flow
```

This unregisters the hooks. Per-repo `.worktrees/` directories and `.claude/worktree-flow.json` files are left in place — clean those up manually if desired.

If you added a `statusLine` entry to `~/.claude/settings.json` during install, remove it manually.

## Version

1.1.0
