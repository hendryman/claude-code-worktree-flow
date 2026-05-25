#!/usr/bin/env bash
# archive-plans.sh — move plan files older than N days into archive/YYYY-MM/
#
# Rationale: ~/.claude/plans/ tends to accumulate hundreds of files (one per
# plan-mode turn). They're useful for a couple of weeks, then become noise.
# This script moves plans beyond AGE_DAYS into per-month subdirectories so
# the top-level listing stays focused on current work.
#
# Called from session-start.sh (background, non-fatal). Also safe to run
# manually: `bash ~/.claude/worktree-flow/scripts/archive-plans.sh`.

set -eu

AGE_DAYS="${AGE_DAYS:-14}"
PLANS_DIR="${PLANS_DIR:-$HOME/.claude/plans}"
ARCHIVE_ROOT="$PLANS_DIR/archive"

[[ -d "$PLANS_DIR" ]] || exit 0

mkdir -p "$ARCHIVE_ROOT"

moved=0
while IFS= read -r -d '' f; do
    yyyymm=$(date -r "$f" +%Y-%m 2>/dev/null || echo "unknown")
    dest="$ARCHIVE_ROOT/$yyyymm"
    mkdir -p "$dest"
    if mv "$f" "$dest/" 2>/dev/null; then
        moved=$((moved + 1))
    fi
done < <(find "$PLANS_DIR" -maxdepth 1 -name '*.md' -type f -mtime +"$AGE_DAYS" -print0 2>/dev/null)

if [[ "$moved" -gt 0 ]]; then
    echo "📦 Archived $moved plan(s) older than ${AGE_DAYS}d → $ARCHIVE_ROOT/"
fi

exit 0
