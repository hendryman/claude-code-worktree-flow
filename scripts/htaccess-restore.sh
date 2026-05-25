#!/bin/bash
# htaccess-restore.sh <worktree-abs-path>
#   Reverse of htaccess-disable-auth.sh.
#
#   Walks <path> for every .htaccess-backup (skipping .git, .worktrees,
#   node_modules, vendor). For each, clears skip-worktree on the sibling
#   .htaccess, removes it, and moves the backup into place.
#
#   Idempotent, no-op when no .htaccess-backup files exist.

set -eu

WT="${1:-}"
if [[ -z "$WT" || ! -d "$WT" ]]; then
    echo "usage: htaccess-restore.sh <worktree-abs-path>" >&2
    exit 2
fi

restore_one() {
    local bk="$1"
    local ht="${bk%-backup}"

    if git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
        local rel="${ht#$WT/}"
        if git -C "$WT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
            git -C "$WT" update-index --no-skip-worktree "$rel" 2>/dev/null || true
        fi
    fi

    rm -f "$ht"
    mv "$bk" "$ht"
    echo "htaccess: restored ${ht#$WT/}"
}

COUNT=0
while IFS= read -r -d '' bk; do
    restore_one "$bk"
    COUNT=$((COUNT+1))
done < <(find "$WT" \
    \( -path "$WT/.git" -o -path "$WT/.worktrees" -o -name node_modules -o -name vendor \) -prune \
    -o -type f -name .htaccess-backup -print0)

if [[ $COUNT -eq 0 ]]; then
    echo "htaccess: no .htaccess-backup files in $WT — nothing to restore"
fi

if git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_COMMON_DIR="$(git -C "$WT" rev-parse --git-common-dir)"
    case "$GIT_COMMON_DIR" in
        /*) ;;
        *)  GIT_COMMON_DIR="$WT/$GIT_COMMON_DIR" ;;
    esac
    EXCLUDE_FILE="$GIT_COMMON_DIR/info/exclude"
    if [[ -f "$EXCLUDE_FILE" ]]; then
        perl -i -ne 'print unless /^\.htaccess-backup$/' "$EXCLUDE_FILE" 2>/dev/null || true
    fi
fi
