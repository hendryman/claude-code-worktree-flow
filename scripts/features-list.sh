#!/bin/bash
# features-list.sh
#   Print a table of all registered features with status.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/../lib/worktree-state.sh"

state_init
state_reconcile_apache

SLUGS=$(state_slugs)
if [[ -z "$SLUGS" ]]; then
    echo "No active features. Create one with /wt-create <slug>"
    exit 0
fi

printf "%-28s %-36s %-6s %-10s %-10s %-5s %s\n" "FEATURE" "BRANCH" "PORT" "APACHE" "UNCOMMIT" "PLAN" "URL"
printf "%-28s %-36s %-6s %-10s %-10s %-5s %s\n" "-------" "------" "----" "------" "--------" "----" "---"

STATE=$(state_file)
while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue
    entry=$(jq -r --arg s "$slug" '.features[$s]' "$STATE")
    branch=$(echo "$entry" | jq -r '.branch')
    port=$(echo "$entry" | jq -r '.port')
    running=$(echo "$entry" | jq -r '.apache_running')
    abs=$(echo "$entry" | jq -r '.abs_path')
    url=$(echo "$entry" | jq -r '.url')
    plan=$(echo "$entry" | jq -r '.plan_file // empty')

    if [[ "$running" == "true" ]]; then
        status="● running"
    else
        status="○ stopped"
    fi

    # Count uncommitted files in the worktree
    uncommit=0
    if [[ -d "$abs" ]]; then
        uncommit=$(cd "$abs" && git status --short 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [[ -n "$plan" && -f "$plan" ]]; then
        plan_mark="✓"
    else
        plan_mark=""
    fi

    printf "%-28s %-36s %-6s %-10s %-10s %-5s %s\n" "$slug" "$branch" "$port" "$status" "$uncommit" "$plan_mark" "$url"
done <<< "$SLUGS"
