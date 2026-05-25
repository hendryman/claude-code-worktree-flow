#!/bin/bash
# htaccess-disable-auth.sh <worktree-abs-path>
#   Neuter HTTP Basic auth in every .htaccess under <path> so the per-feature
#   Apache serves the site without credential prompts during dev.
#
#   Walks <path> for every .htaccess (skipping .git, .worktrees, node_modules,
#   vendor). For each file that contains auth directives, creates a sibling
#   .htaccess-backup and mutates .htaccess in place.
#
#   Idempotent, auto-detecting, no-op when:
#     - No .htaccess files exist
#     - A given .htaccess has no auth directives
#     - A given .htaccess-backup already exists next to it (already disabled)
#
#   Per-file strategy:
#     1. cp <path>/.htaccess -> <path>/.htaccess-backup (pristine original)
#     2. Comment out AuthType/AuthName/AuthUserFile/AuthGroupFile/
#        AuthBasicProvider/AuthDigestProvider + Require valid-user/user/group
#        lines with a "#WTAUTH# " prefix.
#     3. Inject "Require all granted" (preceded by a #WTAUTH# comment) as the
#        first child of every <RequireAny> block.
#
#   Repo-wide hygiene:
#     - git update-index --skip-worktree <each tracked .htaccess>  (hide mutations from /wt-commit)
#     - Append ".htaccess-backup" to $GIT_COMMON_DIR/info/exclude (matches any depth)
#
#   Restored by htaccess-restore.sh before /wt-merge or /wt-abandon.

set -eu

WT="${1:-}"
if [[ -z "$WT" || ! -d "$WT" ]]; then
    echo "usage: htaccess-disable-auth.sh <worktree-abs-path>" >&2
    exit 2
fi

AUTH_RX='^[[:space:]]*(AuthType|AuthUserFile|Require[[:space:]]+(valid-user|user|group))\b'

disable_one() {
    local ht="$1"
    local bk="${ht}-backup"

    if [[ -f "$bk" ]]; then
        return 1
    fi
    if ! grep -qiE "$AUTH_RX" "$ht"; then
        return 1
    fi

    cp "$ht" "$bk"

    perl -i -pe '
        s|^(\s*)(AuthType\s)|$1#WTAUTH# $2|i;
        s|^(\s*)(AuthName\s)|$1#WTAUTH# $2|i;
        s|^(\s*)(AuthUserFile\s)|$1#WTAUTH# $2|i;
        s|^(\s*)(AuthGroupFile\s)|$1#WTAUTH# $2|i;
        s|^(\s*)(AuthBasicProvider\s)|$1#WTAUTH# $2|i;
        s|^(\s*)(AuthDigestProvider\s)|$1#WTAUTH# $2|i;
        s|^(\s*)(Require\s+valid-user\b)|$1#WTAUTH# $2|i;
        s|^(\s*)(Require\s+user\b)|$1#WTAUTH# $2|i;
        s|^(\s*)(Require\s+group\b)|$1#WTAUTH# $2|i;
        $_ .= "    #WTAUTH# injected next line\n    Require all granted\n" if m|^\s*<RequireAny>\s*$|i;
    ' "$ht"

    echo "htaccess: disabled auth in ${ht#$WT/}"
    if git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
        local rel="${ht#$WT/}"
        if git -C "$WT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
            git -C "$WT" update-index --skip-worktree "$rel" 2>/dev/null || true
        fi
    fi
    return 0
}

COUNT=0
FOUND_ANY=0
while IFS= read -r -d '' ht; do
    FOUND_ANY=1
    if disable_one "$ht"; then
        COUNT=$((COUNT+1))
    fi
done < <(find "$WT" \
    \( -path "$WT/.git" -o -path "$WT/.worktrees" -o -name node_modules -o -name vendor \) -prune \
    -o -type f -name .htaccess -print0)

if [[ $COUNT -eq 0 ]]; then
    if [[ $FOUND_ANY -eq 0 ]]; then
        echo "htaccess: no .htaccess files in $WT — skipping"
    else
        echo "htaccess: nothing to disable in $WT (already disabled or no auth directives)"
    fi
fi

if [[ $COUNT -gt 0 ]] && git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_COMMON_DIR="$(git -C "$WT" rev-parse --git-common-dir)"
    case "$GIT_COMMON_DIR" in
        /*) ;;
        *)  GIT_COMMON_DIR="$WT/$GIT_COMMON_DIR" ;;
    esac
    EXCLUDE_FILE="$GIT_COMMON_DIR/info/exclude"
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    if ! grep -qxF '.htaccess-backup' "$EXCLUDE_FILE" 2>/dev/null; then
        echo '.htaccess-backup' >> "$EXCLUDE_FILE"
    fi
fi
