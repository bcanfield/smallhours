#!/usr/bin/env bash
# test-autofix-cleantree.sh — what auto-fix.sh DOES when the agent leaves the
# working tree clean, driven end to end against a local bare remote with
# stubbed `claude` and `gh`. No network, no tokens, no spend.
#
# Reader: anyone changing the clean-tree routing (ADR 0009) or the pull request
# snapshot it is derived from.
#
# Sibling of test-implement-giveup.sh, and it exists for the same recorded
# reason: the pure decision (lib/autofix.sh, covered in test-autofix.sh) is not
# the part that breaks. The seam is — snapshot the PR, run the agent, diff, and
# route — and a seam nothing exercises is how ADR 0007's preservation path
# shipped broken with every unit test green. The properties below are what
# mediamtx-connect#307 cost a human interrupt to learn:
#
#   1. A repair that leaves no commit but moves CI is NOT a give-up.
#   2. A repair nothing will ever re-check IS a give-up — and says why, rather
#      than blaming the agent for making no changes.
#   3. A run that changed nothing at all still gives up exactly as before.
#   4. The PR body is restored if the agent touches it: `Closes #N` is what
#      closes the issue on merge, and the prompt rule alone is not a boundary.
#
# Run: tests/test-autofix-cleantree.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOFIX="$_dir/../scripts/auto-fix.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-cleantree.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

command -v git >/dev/null || { echo "test-autofix-cleantree: git unavailable — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "test-autofix-cleantree: jq unavailable — skipping";  exit 0; }

# ── Fixture: a bare "origin" with the agent branch the PR heads ──────────────
git init -q --bare "$FIX/remote.git"
git init -q "$FIX/repo"
git -C "$FIX/repo" config user.email t@example.com
git -C "$FIX/repo" config user.name  tester
printf '# Streams\n' > "$FIX/repo/README.md"
git -C "$FIX/repo" add -A
git -C "$FIX/repo" commit -qm base
git -C "$FIX/repo" branch -M main
git -C "$FIX/repo" remote add origin "$FIX/remote.git"
git -C "$FIX/repo" push -q -u origin main
git -C "$FIX/repo" checkout -qb agent/issue-901
printf 'work\n' > "$FIX/repo/toggle.txt"
git -C "$FIX/repo" add -A
git -C "$FIX/repo" commit -qm "the agent's change"
git -C "$FIX/repo" push -q -u origin agent/issue-901

# ── PR state the stub serves; $PR_STATE is rewritten to simulate the agent ───
CHECKS_RED='[{"name":"Build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-30T10:00:00Z","completedAt":"2026-07-30T10:04:00Z"},
             {"name":"Conventional commit format","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-30T10:00:00Z","completedAt":"2026-07-30T10:01:00Z"}]'
# What the consumer's `pull_request: edited` run looks like the moment it starts:
# expensive jobs skipped, the format check queued again.
CHECKS_REFIRED='[{"name":"Build","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-07-30T10:20:00Z","completedAt":"2026-07-30T10:20:01Z"},
                 {"name":"Conventional commit format","status":"QUEUED","conclusion":null,"startedAt":null,"completedAt":null}]'
BODY='Closes #901'
RAW_TITLE='Record toggle has no pending/optimistic state'
FIXED_TITLE='fix(streams): show pending state on record toggle'

pr_state() { # title body checks -> json on stdout
  jq -nc --arg t "$1" --arg b "$2" --argjson c "$3" \
    '{title:$t, body:$b, statusCheckRollup:$c}'
}

mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
args="$*"
case "$1 $2" in
  "pr view")
    case "$args" in
      *"--json labels"*)      printf 'agent\n' ;;
      *"--json state"*)       printf 'OPEN\n' ;;
      *"--json headRefName"*) printf 'agent/issue-901\n' ;;
      *"--json title,body,statusCheckRollup"*) cat "$PR_STATE" ;;
      *) printf '\n' ;;
    esac ;;
  "pr checks") printf 'Conventional commit format\tfail\t1s\n' ;;
  "pr edit")
    while [ $# -gt 0 ]; do
      [ "$1" = "--body" ] && printf '%s' "$2" > "$BODY_RESTORED"
      shift
    done ;;
  "pr comment")
    while [ $# -gt 0 ]; do
      [ "$1" = "--body" ] && printf '%s' "$2" > "$COMMENT_FILE"
      shift
    done ;;
  "issue comment")
    while [ $# -gt 0 ]; do
      [ "$1" = "--body" ] && printf '%s' "$2" > "$ISSUE_COMMENT"
      shift
    done ;;
  "repo view") printf 'main\n' ;;
  *) printf '\n' ;;
esac
exit 0
STUB
chmod +x "$FIX/bin/gh"

# The agent: never dirties the tree, optionally rewrites the PR (a retitle, or
# a body edit it was told not to make), always ends cleanly with a summary.
cat > "$FIX/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${PR_STATE_AFTER:-}" ] && [ -f "$PR_STATE_AFTER" ] && cp "$PR_STATE_AFTER" "$PR_STATE"
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr edit --title"}}]}}'
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"duration_ms":9000,"result":"The code is correct; only the PR title was wrong. Retitled it and made no code changes."}'
STUB
chmod +x "$FIX/bin/claude"

export PATH="$FIX/bin:$PATH"
export GITHUB_REPOSITORY=acme/demo GH_TOKEN=stub CLAUDE_CODE_OAUTH_TOKEN=stub
export SMALLHOURS_CONFIG="$FIX/no-such-config.yml"
export GH_LOG="$FIX/gh.log" COMMENT_FILE="$FIX/comment.txt"
export ISSUE_COMMENT="$FIX/issue-comment.txt" BODY_RESTORED="$FIX/body-restored.txt"
export PR_STATE="$FIX/pr-state.json"
export SMALLHOURS_RESULT_JSON="$FIX/result.json"
# Drive the stranded path without waiting out the real two-minute window.
export SMALLHOURS_REFIRE_WAIT_SECONDS=0 SMALLHOURS_REFIRE_POLL_SECONDS=1

run_autofix() { # before-state-json after-state-json-or-empty
  printf '%s' "$1" > "$PR_STATE"
  if [ -n "$2" ]; then
    printf '%s' "$2" > "$FIX/pr-state-after.json"
    export PR_STATE_AFTER="$FIX/pr-state-after.json"
  else
    unset PR_STATE_AFTER
  fi
  : > "$GH_LOG"; : > "$COMMENT_FILE"; : > "$ISSUE_COMMENT"; : > "$BODY_RESTORED"
  ( cd "$FIX/repo" && "$AUTOFIX" 7 1 >/dev/null 2>&1 )
  RC=$?
}

case_banner "a retitle that re-fires CI is not a give-up (mediamtx-connect#307)"
run_autofix "$(pr_state "$RAW_TITLE" "$BODY" "$CHECKS_RED")" \
            "$(pr_state "$FIXED_TITLE" "$BODY" "$CHECKS_REFIRED")"
[ "$RC" -eq 0 ] && ok "exits 0 — the CI path owns the PR from here" \
  || bad "exit was $RC, want 0: a green-code PR was handed to a human"
grep -q "human-needed" "$GH_LOG" \
  && bad "labelled the PR human-needed anyway" || ok "no human-needed label"
[ -s "$ISSUE_COMMENT" ] \
  && bad "handed the issue back to a human" || ok "the issue was not handed back"
grep -q "$FIXED_TITLE" "$COMMENT_FILE" \
  && ok "the timeline comment names the new title" \
  || bad "a spent attempt left no explanation on the PR"

case_banner "a retitle nothing will ever re-check is a give-up that says why"
run_autofix "$(pr_state "$RAW_TITLE" "$BODY" "$CHECKS_RED")" \
            "$(pr_state "$FIXED_TITLE" "$BODY" "$CHECKS_RED")"
[ "$RC" -eq 4 ] && ok "exits 4 — nothing will re-run, so a human is needed" \
  || bad "exit was $RC, want 4"
grep -q "pull_request: edited" "$COMMENT_FILE" \
  && ok "the reason names the consumer CI trigger, not the agent" \
  || bad "the give-up does not say why nothing re-fired"
grep -q "made no changes" "$COMMENT_FILE" \
  && bad "still reads as 'the agent made no changes'" \
  || ok "distinguishable from a run that did nothing"

case_banner "a run that changed nothing at all gives up exactly as before"
run_autofix "$(pr_state "$RAW_TITLE" "$BODY" "$CHECKS_RED")" ""
[ "$RC" -eq 4 ] && ok "exits 4" || bad "exit was $RC, want 4"
grep -q "made no changes" "$COMMENT_FILE" \
  && ok "the original reason survives" || bad "the no-changes reason was lost"
grep -q "Its summary:" "$COMMENT_FILE" \
  && ok "still quotes the agent's own account" || bad "agent summary dropped"

case_banner "the PR body is restored if the agent edits it"
run_autofix "$(pr_state "$RAW_TITLE" "$BODY" "$CHECKS_RED")" \
            "$(pr_state "$RAW_TITLE" "Closes #901 — and my own notes" "$CHECKS_RED")"
[ "$(cat "$BODY_RESTORED")" = "$BODY" ] \
  && ok "the pre-run body is written back" \
  || bad "an edited body survived: got '$(cat "$BODY_RESTORED")'"

case_banner "the defensive gates still hold"
printf '%s' "$(pr_state "$RAW_TITLE" "$BODY" "$CHECKS_RED")" > "$PR_STATE"
cat > "$FIX/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$*" in
  *"--json labels"*) printf 'something-else\n' ;;
  *) printf '\n' ;;
esac
exit 0
STUB
chmod +x "$FIX/bin/gh"
: > "$GH_LOG"
( cd "$FIX/repo" && "$AUTOFIX" 7 1 >/dev/null 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok "a PR without the agent label is ignored, exit 0" \
  || bad "non-agent PR exit was $RC, want 0"
grep -q "^gh pr comment" "$GH_LOG" \
  && bad "commented on a PR that is not ours" || ok "said nothing on a PR that is not ours"

echo
echo "test-autofix-cleantree: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
