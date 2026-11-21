#!/bin/bash
# statusline.sh — oh-my-zsh robbyrussell-style worktree-aware status.
#
# Outputs (ANSI-colored):
#   atadev git:(main)                                        # clean main
#   atadev git:(main*)                                       # dirty main
#   atadev git:(main*↑2)                                     # dirty + ahead of origin
#   atadev git:(main) → dedup git:(claude/dedup*) :8171      # inside worktree w/ apache
#
# Usage from settings.json / statusline-combined.sh. Reads Claude JSON on stdin
# and discards it — we get everything from git + .worktrees/state.json directly.

set -eu

# Drain stdin if piped
if [[ ! -t 0 ]]; then
    cat >/dev/null 2>&1 || true
fi

# Use printf-safe escape via $'...' so the colors render in Claude Code's statusLine
B=$'\033[1m'; RST=$'\033[0m'
BLUE=$'\033[34m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; RED=$'\033[31m'

git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

COMMON_DIR=$(git rev-parse --git-common-dir)
# --git-common-dir returns a path relative to cwd when it points at the main checkout's .git
case "$COMMON_DIR" in
    /*) ;;
    *)  COMMON_DIR=$(cd "$COMMON_DIR" 2>/dev/null && pwd) || COMMON_DIR="" ;;
esac
[[ -z "$COMMON_DIR" ]] && exit 0

MAIN_ROOT=$(cd "$COMMON_DIR/.." && pwd)
REPO_NAME=$(basename "$MAIN_ROOT")

# Compose a "reponame git:(branch<markers>)" segment for an arbitrary checkout.
git_segment() {
    local dir="$1" label="$2"
    local branch dirty ahead behind marker upstream a b branch_color

    branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null \
             || git -C "$dir" rev-parse --short HEAD 2>/dev/null \
             || echo "?")

    dirty=""
    if [[ -n $(git -C "$dir" status --porcelain 2>/dev/null) ]]; then
        dirty="*"
    fi

    ahead=""; behind=""
    upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [[ -n "$upstream" ]]; then
        if read -r a b < <(git -C "$dir" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null); then
            [[ "${a:-0}" -gt 0 ]] && ahead="↑$a"
            [[ "${b:-0}" -gt 0 ]] && behind="↓$b"
        fi
    fi
    marker="${dirty}${ahead}${behind}"

    branch_color=$GREEN
    [[ -n "$dirty" ]] && branch_color=$RED

    printf '%s%s%s%s %sgit:(%s%s%s%s%s%s%s%s)%s' \
        "$B" "$BLUE" "$label" "$RST" \
        "$CYAN" "$RST" \
        "$branch_color" "$branch" "$RST" \
        "$YELLOW" "$marker" "$RST" \
        "$CYAN" "$RST"
}

# Compose a bold "slug*↑↓" segment for the worktree side — no git:(branch)
# duplication; the slug IS the identity, markers mirror the main segment's
# dirty/ahead/behind grammar.
worktree_label() {
    local dir="$1" label="$2"
    local dirty ahead behind marker upstream a b label_color

    dirty=""
    if [[ -n $(git -C "$dir" status --porcelain 2>/dev/null) ]]; then
        dirty="*"
    fi

    ahead=""; behind=""
    upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [[ -n "$upstream" ]]; then
        if read -r a b < <(git -C "$dir" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null); then
            [[ "${a:-0}" -gt 0 ]] && ahead="↑$a"
            [[ "${b:-0}" -gt 0 ]] && behind="↓$b"
        fi
    fi
    marker="${dirty}${ahead}${behind}"

    label_color=$BLUE
    [[ -n "$dirty" ]] && label_color=$RED

    printf '%s%s%s%s%s%s%s' \
        "$B" "$label_color" "$label" "$RST" \
        "$YELLOW" "$marker" "$RST"
}

MAIN_SEG=$(git_segment "$MAIN_ROOT" "$REPO_NAME")

# Worktree segment (only if $PWD is inside a registered worktree)
STATE_FILE="$MAIN_ROOT/.worktrees/state.json"
WT_SEG=""; PORT_SEG=""

WT_ARROW=""

if [[ -f "$STATE_FILE" ]]; then
    here=$(pwd -P 2>/dev/null || pwd)
    # Bind .value.abs_path to $a BEFORE the $p|startswith(...) pipeline.
    # Without the binding, `.value` inside the pipe resolves against the
    # piped-in string $p, not the current entry — jq aborts the whole
    # iteration as soon as it hits a non-matching feature, and the shell's
    # 2>/dev/null swallows the error. That silent break is why Tier 1 only
    # ever worked for the FIRST feature in iteration order.
    slug=$(jq -r --arg p "$here" '
        .features | to_entries[]
        | .value.abs_path as $a
        | select($p == $a or ($p | startswith($a + "/")))
        | .key
    ' "$STATE_FILE" 2>/dev/null | head -1)

    if [[ -n "$slug" && "$slug" != "null" ]]; then
        WT_ARROW=" → "
    else
        # Tier 2: per-session bucket. cwd is main checkout but a worktree is
        # logically active for THIS Claude session (chosen via plan-mode gate
        # or /wt-create). Pointer at state.sessions["claude:<session-id>"],
        # else state.sessions[<tsid>] where <tsid> = ITERM_SESSION_ID (or
        # TERM_SESSION_ID). The pane bucket is cleared on every
        # SessionStart:startup so a fresh Claude session always begins with a
        # blank worktree pointer — the "current worktree" is a property of the
        # Claude session, NOT repo-level persistent state.
        tsid="${ITERM_SESSION_ID:-${TERM_SESSION_ID:-_default}}"
        maybe=""
        if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
            maybe=$(jq -r --arg k "claude:$CLAUDE_SESSION_ID" '.sessions[$k].active_slug // empty' "$STATE_FILE" 2>/dev/null)
        fi
        if [[ -z "$maybe" ]]; then
            maybe=$(jq -r --arg tsid "$tsid" '.sessions[$tsid].active_slug // empty' "$STATE_FILE" 2>/dev/null)
        fi
        if [[ -n "$maybe" ]]; then
            ok=$(jq -r --arg s "$maybe" '
                .features[$s] as $f
                | if $f == null then "missing"
                  elif ($f.status // "active") != "active" then "stale"
                  else "ok"
                  end
            ' "$STATE_FILE" 2>/dev/null)
            if [[ "$ok" == "ok" ]]; then
                abs_check=$(jq -r --arg s "$maybe" '.features[$s].abs_path' "$STATE_FILE" 2>/dev/null)
                if [[ -n "$abs_check" && -d "$abs_check" ]]; then
                    slug="$maybe"
                    WT_ARROW=" ⤳ "
                fi
            fi
        fi
    fi

    if [[ -n "$slug" && "$slug" != "null" ]]; then
        abs=$(jq -r --arg s "$slug" '.features[$s].abs_path' "$STATE_FILE" 2>/dev/null)
        if [[ -n "$abs" && "$abs" != "null" && -d "$abs" ]]; then
            WT_SEG=$(worktree_label "$abs" "$slug")
        fi
        pid=$(jq -r --arg s "$slug" '.features[$s].apache_pid // empty' "$STATE_FILE" 2>/dev/null)
        port=$(jq -r --arg s "$slug" '.features[$s].port' "$STATE_FILE" 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "null" ]] && kill -0 "$pid" 2>/dev/null; then
            PORT_SEG=" ${GREEN}:${port}${RST}"
        fi
    fi
fi

# Touch this session's state bucket so reconciliation knows it's still alive
# (best-effort; silent failure is fine).
if [[ -f "$STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../lib/worktree-state.sh" 2>/dev/null || true
    if declare -F state_touch_session >/dev/null 2>&1; then
        state_touch_session 2>/dev/null || true
    fi
fi

if [[ -n "$WT_SEG" ]]; then
    printf '%s%s%s%s\n' "$MAIN_SEG" "$WT_ARROW" "$WT_SEG" "$PORT_SEG"
else
    printf '%s\n' "$MAIN_SEG"
fi
