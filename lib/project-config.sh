#!/bin/bash
# project-config.sh — load per-project worktree-flow config with defaults
#
# Project overrides: <repo>/.claude/worktree-flow.json
# Defaults merge with overrides; project keys win.

_config_defaults() {
    cat << 'EOF'
{
    "base_branch": "main",
    "branch_prefix": "claude",
    "env_files": [],
    "runtime_symlinks": [],
    "plan_commit_dir": "",
    "merge_strategy": "merge",
    "commit_coauthor": "Claude Opus 4.7 (1M context) <noreply@anthropic.com>",
    "auto_push_on_commit": true,
    "delete_branch_on_merge": true
}
EOF
}

# Print merged config as JSON. Project keys override defaults.
config_load() {
    local repo_root project_cfg defaults
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        _config_defaults
        return
    }
    project_cfg="$repo_root/.claude/worktree-flow.json"
    defaults=$(_config_defaults)
    if [[ -f "$project_cfg" ]]; then
        jq -s '.[0] * .[1]' <(echo "$defaults") "$project_cfg"
    else
        echo "$defaults"
    fi
}

# Get a single key from merged config. Usage: config_get <key>
config_get() {
    config_load | jq -r --arg k "$1" '.[$k]'
}
