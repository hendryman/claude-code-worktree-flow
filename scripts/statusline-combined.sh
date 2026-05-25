#!/bin/bash
# statusline-combined.sh
#   Prepend worktree-flow indicators to claude-hud output.
#   Reads Claude Code's JSON on stdin, forwards it to claude-hud, adds wtf prefix.

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/worktree-flow}"
NODE_BIN="$(command -v node 2>/dev/null || echo node)"

INPUT=$(cat 2>/dev/null || true)

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

WTF=$(CLAUDE_SESSION_ID="$SESSION_ID" bash "$PLUGIN_ROOT/scripts/statusline.sh" < /dev/null 2>/dev/null || true)

HUD_DIST=$(ls -td "$HOME/.claude/plugins/cache/claude-hud/claude-hud/"*/ 2>/dev/null | head -1)
HUD_OUT=""
if [[ -n "$HUD_DIST" && -f "${HUD_DIST}dist/index.js" ]]; then
    HUD_OUT=$(printf '%s' "$INPUT" | "$NODE_BIN" "${HUD_DIST}dist/index.js" 2>/dev/null || true)
    # Strip claude-hud's trailing project-name segment on the header line.
    # worktree-flow's prefix already shows <repo>, so the trailing yellow
    # project name is pure duplication. Claude-hud uses NBSP (U+00A0, bytes
    # c2 a0) around its `|` separators, hence the explicit byte match.
    HUD_OUT=$(printf '%s' "$HUD_OUT" | perl -0777 -pe 's/\xc2\xa0\|\xc2\xa0\x1b\[33m[^\x1b]+\x1b\[0m(?=\n|\z)//g')
fi

if [[ -n "$WTF" && -n "$HUD_OUT" ]]; then
    printf '%s │ %s\n' "$WTF" "$HUD_OUT"
elif [[ -n "$WTF" ]]; then
    printf '%s\n' "$WTF"
else
    printf '%s\n' "$HUD_OUT"
fi
