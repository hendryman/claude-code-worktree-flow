#!/bin/bash
# Exercises branch-guard.sh / plan-exec-guard.sh against throwaway repos.
# Usage: tests/guards.sh [<plugin-root>] [<bash-binary>]   (defaults: this repo, bash)
set -u
PLUGIN="${1:-$(cd "$(dirname "$0")/.." && pwd)}"; SH="${2:-bash}"
T=$(mktemp -d "${TMPDIR:-/tmp}/wtf-test.XXXXXX"); T=$(cd "$T" && pwd -P)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "$2" | sed 's/^/       /' | head -8; }

mkrepo() {
    git init -q -b main "$1"
    printf 'x\n' > "$1/app.php"; printf 'secret.env\n' > "$1/.gitignore"; mkdir -p "$1/sub"; printf 'y\n' > "$1/sub/lib.php"
    git -C "$1" add -A && git -C "$1" commit -qm init
}
mkrepo "$T/repo-a"; mkrepo "$T/repo-b"
printf 's\n' > "$T/repo-a/secret.env"

marker() { printf '/tmp/claude-wtf-plan-exec-ok-%s' "$(printf '%s' "$1" | md5 -q)"; }
rm -f "$(marker "$T/repo-a")" "$(marker "$T/repo-b")"

edit_json() { jq -nc --arg p "$1" --arg s "$2" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p}}'; }
plan_json() { jq -nc --arg s "$1" '{tool_name:"ExitPlanMode",session_id:$s}'; }
# run_branch <file> <session> <pane> [<claude-env-session>]
run_branch() { edit_json "$1" "$2" | env -u TERM_SESSION_ID ITERM_SESSION_ID="$3" CLAUDE_CODE_SESSION_ID="${4:-}" "$SH" "$PLUGIN/hooks/branch-guard.sh"; }
run_plan()   { (cd "$1" && plan_json "$2" | env -u TERM_SESSION_ID ITERM_SESSION_ID="$3" CLAUDE_CODE_SESSION_ID="${4:-}" "$SH" "$PLUGIN/hooks/plan-exec-guard.sh"); }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // (if .hookSpecificOutput.additionalContext then "context" else "none" end)' 2>/dev/null || echo none; }

echo "== before any worktree"
one_question() { [[ "$1" == *"Worktree slug for \`repo-a\`, or stay on \`main\`?"* && "$1" == *'\"Use main\" — '*'\"<slug>\"'* && "$1" != *'Slug?'* && "$1" != *'\"Use plan filename\"'* ]]; }
out=$(run_branch "$T/repo-a/app.php" S1 P1 S1); [[ $(decision "$out") == deny && "$out" == *"INVOKE AskUserQuestion"* ]] && ok "edit on main asks" || bad "edit on main asks" "$out"
one_question "$out" && ok "edit gate: one slug question, Use main first" || bad "edit gate: one slug question" "$out"
out=$(run_plan "$T/repo-a" S1 P1 S1);          [[ $(decision "$out") == deny && "$out" == *"INVOKE AskUserQuestion"* ]] && ok "plan exit asks" || bad "plan exit asks" "$out"
one_question "$out" && ok "plan gate: one slug question, Use main first" || bad "plan gate: one slug question" "$out"
[[ "$out" == *"(cd \\\"$T/repo-a\\\" && bash \\\"$PLUGIN/scripts/feature-create.sh\\\" <slug>)"* ]] && ok "ask text has resolved create command" || bad "ask text has resolved create command" "$out"

echo "== session S1 (pane P1) creates worktree feat-x in repo-a"
(cd "$T/repo-a" && env -u TERM_SESSION_ID ITERM_SESSION_ID=P1 CLAUDE_CODE_SESSION_ID=S1 "$SH" "$PLUGIN/scripts/feature-create.sh" feat-x >/dev/null 2>"$T/create.err") && ok "feature-create ran" || bad "feature-create ran" "$(cat "$T/create.err")"
[[ ! -e "$(marker "$T/repo-a")" ]] && ok "no 5-min marker left behind" || bad "no 5-min marker left behind" "marker exists"
jq -e '.sessions["claude:S1"].active_slug == "feat-x" and .sessions["P1"].active_slug == "feat-x"' "$T/repo-a/.worktrees/state.json" >/dev/null && ok "pointer under claude key + pane key" || bad "pointer keys" "$(jq .sessions "$T/repo-a/.worktrees/state.json")"
WT="$T/repo-a/.worktrees/feat-x"

echo "== same session, worktree active"
out=$(run_plan "$T/repo-a" S1 P1 S1); [[ $(decision "$out") == context && "$out" == *"$WT/"* ]] && ok "plan exit passes with worktree note" || bad "plan exit passes with worktree note" "$out"
out=$(run_plan "$T/repo-a" S1 P1 S1); [[ $(decision "$out") == context ]] && ok "plan exit passes again (no 5-min / one-shot expiry)" || bad "plan exit passes again" "$out"
out=$(run_branch "$T/repo-a/sub/lib.php" S1 P1 S1); [[ $(decision "$out") == deny && "$out" == *"$WT/sub/lib.php"* && "$out" != *"AskUserQuestion"* ]] && ok "main-checkout edit redirected to worktree path, no question" || bad "redirect" "$out"
out=$(run_branch "$T/repo-a/secret.env" S1 P1 S1); [[ -z "$out" ]] && ok "gitignored file in main checkout passes" || bad "gitignored passes" "$out"
out=$(run_branch "$WT/app.php" S1 P1 S1); [[ -z "$out" ]] && ok "edit inside worktree passes" || bad "edit inside worktree passes" "$out"
out=$(run_plan "$T/repo-a" S1 P9 ""); [[ $(decision "$out") == context ]] && ok "resume in another pane (stdin session id only)" || bad "resume in another pane" "$out"
out=$(run_plan "$T/repo-a" S7 P1 S7); [[ $(decision "$out") == context ]] && ok "/clear in same pane (pane key)" || bad "/clear in same pane" "$out"

echo "== other sessions are not affected"
out=$(run_branch "$T/repo-a/app.php" S2 P2 S2); [[ "$out" == *"INVOKE AskUserQuestion"* ]] && ok "other session/pane still asked" || bad "other session asked" "$out"
out=$(run_plan "$T/repo-a" S2 P2 S2);          [[ "$out" == *"INVOKE AskUserQuestion"* ]] && ok "other session plan exit still asked" || bad "other session plan asked" "$out"

echo "== second repo: asked on its own, once"
out=$(run_branch "$T/repo-b/app.php" S1 P1 S1); [[ "$out" == *"INVOKE AskUserQuestion"* && "$out" == *"Worktree slug for \`repo-b\`"* &&"$out" == *"(cd \\\"$T/repo-b\\\""* ]] && ok "repo-b asks, names repo-b, cds into it" || bad "repo-b asks" "$out"
(cd "$T/repo-b" && env -u TERM_SESSION_ID ITERM_SESSION_ID=P1 CLAUDE_CODE_SESSION_ID=S1 "$SH" "$PLUGIN/scripts/feature-create.sh" feat-x >/dev/null 2>&1)
out=$(run_branch "$T/repo-b/app.php" S1 P1 S1); [[ "$out" == *"repo-b/.worktrees/feat-x/app.php"* && "$out" != *"AskUserQuestion"* ]] && ok "repo-b redirected after its worktree exists" || bad "repo-b redirect" "$out"

echo "== On-main escape still 5 min, and wins over the worktree"
touch "$(marker "$T/repo-a")"
out=$(run_branch "$T/repo-a/app.php" S1 P1 S1); [[ -z "$out" ]] && ok "fresh marker lets main edit through" || bad "marker" "$out"
touch -t "$(date -v-6M +%Y%m%d%H%M.%S)" "$(marker "$T/repo-a")"
out=$(run_branch "$T/repo-a/app.php" S2 P2 S2); [[ "$out" == *"INVOKE AskUserQuestion"* ]] && ok "stale marker (>5 min) asks again" || bad "stale marker" "$out"

echo "== no iTerm: shared _default bucket must not leak between sessions"
(cd "$T/repo-a" && env -u TERM_SESSION_ID -u ITERM_SESSION_ID CLAUDE_CODE_SESSION_ID=S5 "$SH" "$PLUGIN/scripts/feature-create.sh" feat-x >/dev/null 2>&1)
out=$(edit_json "$T/repo-a/app.php" S6 | env -u TERM_SESSION_ID -u ITERM_SESSION_ID CLAUDE_CODE_SESSION_ID=S6 "$SH" "$PLUGIN/hooks/branch-guard.sh"); [[ "$out" == *"INVOKE AskUserQuestion"* ]] && ok "S6 not handed S5's worktree via _default" || bad "_default leak" "$out"
out=$(edit_json "$T/repo-a/app.php" S5 | env -u TERM_SESSION_ID -u ITERM_SESSION_ID CLAUDE_CODE_SESSION_ID=S5 "$SH" "$PLUGIN/hooks/branch-guard.sh"); [[ "$out" == *".worktrees/feat-x/app.php"* ]] && ok "S5 redirected via its claude key" || bad "S5 claude key" "$out"

echo "== stale feature (worktree dir gone) asks again"
git -C "$T/repo-a" worktree remove --force "$WT"
out=$(run_branch "$T/repo-a/app.php" S1 P1 S1); [[ "$out" == *"INVOKE AskUserQuestion"* ]] && ok "missing worktree dir → ask" || bad "missing dir" "$out"

echo "== statusline reads the claude key"
rm -f "$(marker "$T/repo-a")" "$(marker "$T/repo-b")"
sl=$(cd "$T/repo-b" && env -u TERM_SESSION_ID ITERM_SESSION_ID=P42 CLAUDE_SESSION_ID=S1 "$SH" "$PLUGIN/scripts/statusline.sh" </dev/null 2>/dev/null)
[[ "$sl" == *feat-x* ]] && ok "statusline shows worktree after pane change" || bad "statusline" "$sl"

rm -rf "$T"
echo "== $pass passed, $fail failed ($SH)"
[[ $fail -eq 0 ]]
