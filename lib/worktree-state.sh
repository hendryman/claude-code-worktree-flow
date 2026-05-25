#!/bin/bash
# worktree-state.sh — helpers for .worktrees/state.json
#
# Source this from slash-command scripts:
#   source "$(git rev-parse --show-toplevel)/.claude/lib/worktree-state.sh"
#
# All functions assume caller is in a git repo (main checkout or a worktree).

set -eu

_state_repo_root() {
    # Resolve to the MAIN checkout root (not worktree root)
    local common_dir
    common_dir=$(git rev-parse --git-common-dir)
    # common-dir is <repo>/.git; parent is the repo root
    (cd "$common_dir/.." && pwd)
}

state_file() {
    echo "$(_state_repo_root)/.worktrees/state.json"
}

state_init() {
    local f
    f=$(state_file)
    mkdir -p "$(dirname "$f")"
    if [[ ! -f "$f" ]]; then
        cat > "$f" << 'EOF'
{
  "features": {},
  "port_range": [8100, 8199],
  "schema_version": 1
}
EOF
    fi
    # Dropbox ignore flag (idempotent)
    xattr -w com.dropbox.ignored 1 "$(_state_repo_root)/.worktrees" 2>/dev/null || true
}

# Deterministic "preferred" port for a path. Kept for backwards-compat with
# tools that only know the path. Paths sharing a long prefix (all worktrees
# do, under .worktrees/<slug>) collide heavily under `cksum % 100` because
# CRC-32 is near-periodic in the low bits for same-prefix inputs. Callers
# that have a slug handy should use state_allocate_port() instead, which
# probes for a free slot in state.json.
# Usage: state_port_for_path <absolute-path>
state_port_for_path() {
    local path="$1"
    local c
    c=$(echo "$path" | cksum | cut -d' ' -f1)
    echo $((8100 + c % 100))
}

# Collision-aware port allocator. Seeds with the deterministic hash of
# <abs_path>, then linearly probes within [8100, 8199] skipping ports already
# owned by a DIFFERENT feature in state.json. Idempotent: calling twice for
# the same slug returns the same port (because the allocator excludes the
# caller's own entry from the "used" set).
#
# Usage: state_allocate_port <abs_path> <slug>
# Prints the port on stdout. Exits non-zero if range is exhausted.
state_allocate_port() {
    local path="$1" slug="$2"
    local start=8100 end=8199 span c preferred p tries used
    span=$((end - start + 1))
    c=$(echo "$path" | cksum | cut -d' ' -f1)
    preferred=$((start + c % span))

    used=$(jq -r --arg s "$slug" \
        '.features | to_entries[]
         | select(.key != $s)
         | select(.value.status == "active")
         | .value.port' \
        "$(state_file)" 2>/dev/null || true)

    for tries in $(seq 0 $((span - 1))); do
        p=$(( (preferred - start + tries) % span + start ))
        if ! grep -Fxq "$p" <<< "$used"; then
            echo "$p"
            return 0
        fi
    done

    echo "ERROR: port range [$start-$end] exhausted" >&2
    return 1
}

# Return the slug (if any) whose state entry claims <port> AND whose apache
# is currently alive, excluding <self_slug>. Empty if none.
# Usage: state_port_owner <port> [<self_slug>]
state_port_owner() {
    local port="$1" self="${2:-}"
    jq -r --arg p "$port" --arg self "$self" '
        .features | to_entries[]
        | select(.key != $self)
        | select(.value.port == ($p | tonumber))
        | select(.value.apache_pid != null)
        | .key
    ' "$(state_file)" 2>/dev/null | while read -r other_slug; do
        local other_pid
        other_pid=$(jq -r --arg s "$other_slug" '.features[$s].apache_pid // empty' "$(state_file)")
        if [[ -n "$other_pid" ]] && kill -0 "$other_pid" 2>/dev/null; then
            echo "$other_slug"
            return 0
        fi
    done
}

# Get a feature entry as JSON. Returns empty if not found.
# Usage: state_get <slug>
state_get() {
    local slug="$1"
    jq -r --arg s "$slug" '.features[$s] // empty' "$(state_file)"
}

# Check if feature exists. Usage: state_has <slug>
state_has() {
    local slug="$1"
    local r
    r=$(jq -r --arg s "$slug" '.features | has($s)' "$(state_file)")
    [[ "$r" == "true" ]]
}

# Put/update a feature. Pass JSON as $2.
# Usage: state_put <slug> '{"branch":"...","path":"..."}'
state_put() {
    local slug="$1" payload="$2" f
    f=$(state_file)
    local tmp="${f}.tmp.$$"
    jq --arg s "$slug" --argjson v "$payload" '.features[$s] = $v' "$f" > "$tmp"
    mv "$tmp" "$f"
}

# Remove a feature entry.
state_remove() {
    local slug="$1" f tmp
    f=$(state_file)
    tmp="${f}.tmp.$$"
    jq --arg s "$slug" 'del(.features[$s])' "$f" > "$tmp"
    mv "$tmp" "$f"
}

# Update a single field on a feature.
# Usage: state_set <slug> <field> <value-as-json>
state_set() {
    local slug="$1" field="$2" value="$3" f tmp
    f=$(state_file)
    tmp="${f}.tmp.$$"
    jq --arg s "$slug" --arg k "$field" --argjson v "$value" \
        '.features[$s][$k] = $v' "$f" > "$tmp"
    mv "$tmp" "$f"
}

# List feature slugs (one per line).
state_slugs() {
    jq -r '.features | keys[]' "$(state_file)" 2>/dev/null || true
}

# Resolve slug from current $PWD. Empty if not inside any registered worktree.
state_slug_for_pwd() {
    local here
    here=$(pwd -P)
    jq -r --arg p "$here" '
        .features | to_entries[]
        | (.value.abs_path) as $a
        | select($p == $a or ($p | startswith($a + "/")))
        | .key
    ' "$(state_file)" 2>/dev/null | head -1
}

# Is a PID alive? Returns 0/1.
state_pid_alive() {
    local pid="$1"
    [[ -n "$pid" && "$pid" != "null" ]] && kill -0 "$pid" 2>/dev/null
}

# Reconcile apache_running flag for all features (mutates state).
state_reconcile_apache() {
    local slug pid f tmp
    f=$(state_file)
    for slug in $(state_slugs); do
        pid=$(jq -r --arg s "$slug" '.features[$s].apache_pid // empty' "$f")
        if state_pid_alive "$pid"; then
            state_set "$slug" "apache_running" "true"
        else
            state_set "$slug" "apache_running" "false"
        fi
    done
}

# ─── Per-session active-slug (worktree pointer scoped to terminal pane) ──
# state.json grows a top-level `sessions` map, keyed by TERM_SESSION_ID
# (iTerm's per-pane UUID — stable across tool invocations within one Claude
# session). Replaces the old /tmp/claude-active-slug-<repo-hash> marker,
# which was shared across ALL sessions on the repo and leaked stale values
# whenever two sessions ran concurrently or one merged via GitHub's web UI.
#
# Entry shape:
#   .sessions["<tsid>"] = { "active_slug": "<slug>", "last_seen": "<iso>" }
#
# Each session writes only its own bucket. Reconciliation prunes buckets
# whose `last_seen` is older than 7 days or whose active_slug points at a
# stale/removed feature.

state_tsid() {
    # Prefer iTerm's stable per-pane UUID, fall back to generic TERM_SESSION_ID,
    # finally a literal "_default" bucket for one-off shells that set neither.
    local id="${ITERM_SESSION_ID:-${TERM_SESSION_ID:-}}"
    printf '%s' "${id:-_default}"
}

state_set_active_slug() {
    # Writes ONE pointer:
    #   .sessions[$tsid] — per-Claude-session, scoped to this iTerm pane
    #
    # The pointer is cleared on every SessionStart:startup, so a fresh
    # Claude session always begins with a blank worktree pointer. The
    # "current worktree" is a session property, NOT repo-level persistent
    # state. There is intentionally no repo-wide fallback — that would
    # leak an old session's worktree pointer into a new session.
    local slug="$1" f tmp ts tsid
    tsid=$(state_tsid)
    f=$(state_file)
    tmp="${f}.tmp.$$"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq --arg tsid "$tsid" --arg s "$slug" --arg t "$ts" '
        (.sessions //= {})
        | .sessions[$tsid] = {active_slug: $s, last_seen: $t}
        | del(.current_active_slug)
    ' "$f" > "$tmp"
    mv "$tmp" "$f"
}

state_touch_session() {
    # Update last_seen without changing active_slug (called from statusline).
    local f tmp ts tsid
    tsid=$(state_tsid)
    [[ "$tsid" == "_default" ]] && return 0
    f=$(state_file)
    [[ -f "$f" ]] || return 0
    tmp="${f}.tmp.$$"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq --arg tsid "$tsid" --arg t "$ts" '
        if (.sessions[$tsid] // null) != null
        then .sessions[$tsid].last_seen = $t
        else .
        end
    ' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

state_clear_active_slug() {
    local f tmp tsid
    tsid=$(state_tsid)
    f=$(state_file)
    tmp="${f}.tmp.$$"
    jq --arg tsid "$tsid" 'if .sessions then del(.sessions[$tsid]) else . end' \
        "$f" > "$tmp"
    mv "$tmp" "$f"
}

state_get_active_slug() {
    local tsid
    tsid=$(state_tsid)
    jq -r --arg tsid "$tsid" '.sessions[$tsid].active_slug // empty' \
        "$(state_file)" 2>/dev/null || true
}

# Clear this-session's bucket IF it points at the given slug. Used by merge
# and abandon so a session doesn't stomp on another session's pointer.
state_clear_active_slug_if() {
    local want="$1" current
    current=$(state_get_active_slug)
    [[ "$current" == "$want" ]] && state_clear_active_slug
}

# Also clear ANY session whose active_slug is the given slug — used by merge
# / abandon so the removed feature doesn't linger as a pointer in any
# session's bucket (including sessions that aren't running anymore). Also
# strips any legacy repo-wide current_active_slug pointer that pre-dates
# strict per-session scoping.
state_clear_active_slug_everywhere() {
    local slug="$1" f tmp
    f=$(state_file)
    tmp="${f}.tmp.$$"
    jq --arg s "$slug" '
        (if .sessions then
            .sessions |= with_entries(
                select(.value.active_slug != $s)
            )
        else . end)
        | del(.current_active_slug)
    ' "$f" > "$tmp"
    mv "$tmp" "$f"
}

# Walk features. Verify abs_path + git worktree registration. Mark missing
# ones as status=stale. GC session buckets older than 7 days. Clear any
# session's active_slug pointing at a stale/missing feature. Idempotent.
state_reconcile_features() {
    local slug abs repo_root f tmp worktree_paths cutoff
    f=$(state_file)
    repo_root=$(_state_repo_root)
    worktree_paths=$(cd "$repo_root" && git worktree list --porcelain 2>/dev/null \
        | awk '/^worktree / { print substr($0, 10) }' || true)

    for slug in $(state_slugs); do
        abs=$(jq -r --arg s "$slug" '.features[$s].abs_path' "$f")
        if [[ ! -d "$abs" ]] || ! grep -Fxq "$abs" <<< "$worktree_paths"; then
            state_set "$slug" "status" '"stale"'
        fi
    done

    # 7-day cutoff for session buckets
    cutoff=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)

    tmp="${f}.tmp.$$"
    jq --arg cutoff "$cutoff" '
        (if .sessions then
            .features as $feats
            | .sessions |= with_entries(
                # Keep the bucket only if: last_seen is recent AND the slug
                # refers to an active feature.
                select(
                    (.value.last_seen // "1970-01-01") > $cutoff
                    and ($feats[.value.active_slug].status // "") == "active"
                )
            )
        else . end)
        # Strip any legacy repo-wide pointer; the active slug is strictly a
        # per-Claude-session property now.
        | del(.current_active_slug)
    ' "$f" > "$tmp"
    mv "$tmp" "$f"
}
