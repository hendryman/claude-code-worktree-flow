#!/bin/bash
# feature-create.sh <slug> [<base-ref>]
#   Creates .worktrees/<slug> on branch <branch-prefix>/<slug> from <base-ref>.
#   Copies env files listed in .claude/worktree-flow.json. Registers in state.json.
#
#   Idempotent: if <slug> is already registered AND its worktree dir exists on
#   disk, prints a "Resumed" banner and exits 0 without re-creating anything.
#   Caller (wt-create / wt-resume) invokes apache-start.sh afterwards.
#
#   If <slug> is registered but the worktree dir is missing, errors out and
#   points the user at /wt-abandon.

set -eu

SLUG="${1:-}"
BASE_REF_OVERRIDE="${2:-}"

if [[ -z "$SLUG" ]]; then
    echo "ERROR: usage: feature-create.sh <slug> [<base-ref>]" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/../lib/worktree-state.sh"
source "$SCRIPT_DIR/../lib/project-config.sh"

# Normalize slug
SLUG=$(echo "$SLUG" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | sed 's/[^a-z0-9-]//g' | sed 's/^-*//;s/-*$//')
if [[ -z "$SLUG" || ${#SLUG} -gt 50 ]]; then
    echo "ERROR: invalid slug '$1' (must yield 1-50 chars, lowercase alphanumeric + hyphens)" >&2
    exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel)

# Must be in the main checkout, not a worktree
if [[ "$(git rev-parse --git-common-dir)" != "$(git rev-parse --git-dir)" ]]; then
    echo "ERROR: run /wt-create from the main checkout, not from inside a worktree" >&2
    exit 2
fi

# Load project config (with defaults)
CONFIG=$(config_load)
BASE_REF="${BASE_REF_OVERRIDE:-$(echo "$CONFIG" | jq -r '.base_branch')}"
BRANCH_PREFIX=$(echo "$CONFIG" | jq -r '.branch_prefix')
ENV_FILES=$(echo "$CONFIG" | jq -r '.env_files[]' 2>/dev/null)

state_init

WT_REL=".worktrees/$SLUG"
WT_ABS="$REPO_ROOT/$WT_REL"
BRANCH="$BRANCH_PREFIX/$SLUG"

if state_has "$SLUG"; then
    EXISTING=$(state_get "$SLUG")
    EX_ABS=$(echo "$EXISTING" | jq -r '.abs_path')
    EX_BRANCH=$(echo "$EXISTING" | jq -r '.branch')
    EX_PORT=$(echo "$EXISTING" | jq -r '.port')
    EX_URL=$(echo "$EXISTING" | jq -r '.url')
    EX_PLAN=$(echo "$EXISTING" | jq -r '.plan_file // empty')

    if [[ -z "$EX_ABS" || "$EX_ABS" == "null" || ! -d "$EX_ABS" ]]; then
        echo "ERROR: feature '$SLUG' registered in state.json but worktree dir missing at:" >&2
        echo "  $EX_ABS" >&2
        echo "" >&2
        echo "Run /wt-abandon $SLUG to clean up, then /wt-create $SLUG to re-create." >&2
        exit 2
    fi

    # Uncommitted file count for the existing worktree
    UNCOMMIT=0
    if [[ -d "$EX_ABS/.git" || -f "$EX_ABS/.git" ]]; then
        UNCOMMIT=$(cd "$EX_ABS" && git status --short 2>/dev/null | wc -l | tr -d ' ')
    fi

    echo "Resuming worktree $WT_REL on branch $EX_BRANCH..."
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Feature:  $SLUG"
    echo "  Branch:   $EX_BRANCH"
    echo "  Path:     $WT_REL"
    echo "  Port:     $EX_PORT"
    echo "  URL:      $EX_URL"
    if [[ -n "$EX_PLAN" && -f "$EX_PLAN" ]]; then
        echo "  Plan:     ${EX_PLAN/#$HOME/~}"
    fi
    echo "  Uncommit: $UNCOMMIT files"
    echo "═══════════════════════════════════════════"
    echo ""
    echo "Next: cd $WT_REL && /wt-apache"

    bash "$SCRIPT_DIR/htaccess-disable-auth.sh" "$EX_ABS" || true

    # Markers: let plan-mode gates yield; statusline reads state.active_slug.
    REPO_HASH=$(printf '%s' "$REPO_ROOT" | md5 -q 2>/dev/null || printf '%s' "$REPO_ROOT" | md5sum | cut -d' ' -f1)
    touch "/tmp/claude-wtf-plan-exec-ok-$REPO_HASH"
    state_set_active_slug "$SLUG"

    exit 0
fi

if [[ -e "$WT_ABS" ]]; then
    echo "ERROR: $WT_REL already exists on disk but is not registered in state.json." >&2
    echo "Clean it up manually (git worktree remove / rm -rf) before re-running /wt-create $SLUG." >&2
    exit 2
fi

if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    echo "ERROR: base ref '$BASE_REF' not found" >&2
    exit 2
fi
BASE_SHA=$(git rev-parse --short "$BASE_REF")

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "ERROR: branch '$BRANCH' already exists locally" >&2
    exit 2
fi

echo "Creating worktree $WT_REL on branch $BRANCH from $BASE_REF ($BASE_SHA)..."
git worktree add "$WT_ABS" -b "$BRANCH" "$BASE_REF" >/dev/null

# Copy env/config files (gitignored but needed at runtime)
COPIED=()
while IFS= read -r ef; do
    [[ -z "$ef" ]] && continue
    if [[ -f "$REPO_ROOT/$ef" ]]; then
        mkdir -p "$WT_ABS/$(dirname "$ef")"
        cp "$REPO_ROOT/$ef" "$WT_ABS/$ef"
        COPIED+=("$ef")
    fi
done <<< "$ENV_FILES"

# Symlink gitignored runtime-cache dirs (e.g. large binary caches that
# would cost disk to copy per worktree, or need to stay in sync with main).
# Per-project config lists them under `runtime_symlinks`.
RUNTIME_SYMLINKS=$(echo "$CONFIG" | jq -r '.runtime_symlinks[]?' 2>/dev/null)
SYMLINKED=()
while IFS= read -r rs; do
    [[ -z "$rs" ]] && continue
    src="$REPO_ROOT/$rs"
    dst="$WT_ABS/$rs"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        # If git already materialised an (empty) dir at dst, remove it first
        # so the symlink can replace it.
        [[ -d "$dst" && ! -L "$dst" ]] && rmdir "$dst" 2>/dev/null || true
        ln -snf "$src" "$dst" && SYMLINKED+=("$rs")
    fi
done <<< "$RUNTIME_SYMLINKS"

bash "$SCRIPT_DIR/htaccess-disable-auth.sh" "$WT_ABS" || true

# Port: seed from deterministic hash of abs_path, then probe to avoid
# collision with other registered features (cksum % 100 collides heavily
# for paths sharing the .worktrees/ prefix).
PORT=$(state_allocate_port "$WT_ABS" "$SLUG")

# Plan file detection
PLAN_FILE="$HOME/.claude/plans/$SLUG.md"
[[ -f "$PLAN_FILE" ]] || PLAN_FILE=""

PAYLOAD=$(jq -n \
    --arg branch "$BRANCH" \
    --arg path "$WT_REL" \
    --arg abs_path "$WT_ABS" \
    --argjson port "$PORT" \
    --arg url "http://localhost:$PORT/" \
    --arg base_ref "$BASE_REF" \
    --arg base_sha "$BASE_SHA" \
    --arg plan_file "$PLAN_FILE" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
        branch: $branch,
        path: $path,
        abs_path: $abs_path,
        port: $port,
        url: $url,
        apache_pid: null,
        apache_log: ("/tmp/apache-" + ($port|tostring) + ".log"),
        apache_running: false,
        base_ref: $base_ref,
        base_sha: $base_sha,
        plan_file: (if $plan_file == "" then null else $plan_file end),
        created: $created,
        last_commit: null,
        status: "active"
    }')
state_put "$SLUG" "$PAYLOAD"

echo ""
echo "═══════════════════════════════════════════"
echo "  Feature:  $SLUG"
echo "  Branch:   $BRANCH"
echo "  Path:     $WT_REL"
echo "  Port:     $PORT"
echo "  URL:      http://localhost:$PORT/"
if [[ -n "$PLAN_FILE" ]]; then
    echo "  Plan:     ~/.claude/plans/$SLUG.md"
fi
if [[ ${#COPIED[@]} -gt 0 ]]; then
    echo "  Env:      ${COPIED[*]}"
fi
if [[ ${#SYMLINKED[@]} -gt 0 ]]; then
    echo "  Symlinks: ${SYMLINKED[*]}"
fi
echo "═══════════════════════════════════════════"
echo ""
echo "Next: cd $WT_REL && /wt-apache"

# Markers: let plan-mode gates yield (plan-file-gate + plan-exec-guard both
# read /tmp/claude-wtf-plan-exec-ok-<hash>). Active-slug lives in state.json.
REPO_HASH=$(printf '%s' "$REPO_ROOT" | md5 -q 2>/dev/null || printf '%s' "$REPO_ROOT" | md5sum | cut -d' ' -f1)
touch "/tmp/claude-wtf-plan-exec-ok-$REPO_HASH"
state_set_active_slug "$SLUG"
