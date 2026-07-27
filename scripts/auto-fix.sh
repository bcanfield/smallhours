#!/usr/bin/env bash
# auto-fix.sh — T3' body. CI went red on an agent PR and state-manager granted
# attempt N (<= attempt_cap): check out the PR branch, show the agent what
# failed, let it fix, then commit + push (the push re-runs CI, which routes the
# next outcome back through state-manager — green resets the counter, red
# either summons attempt N+1 or gives up at the cap, T4).
#
#   auto-fix.sh <pr-number> <attempt> [ci-run-id]
#
# ci-run-id (the failed consumer workflow_run) enriches the prompt with the
# failed-job log tail when the token can read Actions; enrichment never fails
# the run.
#
# Give-up (Claude CLI failure, or a run that changes nothing — nothing pushed
# means CI never re-fires, so the loop would strand): PR `human-needed`, issue
# ready-for-human + reason, exit 4.
# Env: GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, GITHUB_REPOSITORY. Runs in a clone.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/claude-run.sh"

# Kept OUTSIDE the consumer working tree so `git add -A` never commits it.
RESULT_JSON="${SMALLHOURS_RESULT_JSON:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smallhours-result.json}"

# Cap the inlined log tail — failed E2E logs can be enormous.
_LOG_TAIL_BYTES=20000

_give_up() { # pr issue reason
  local pr="$1" issue="$2" reason="$3" work
  work="$(claude_work_summary "${RESULT_JSON}.work")"
  state_pr_add_label "$pr" human-needed
  [ -n "$issue" ] && state_set_issue "$issue" ready-for-human
  sh_comment_pr "$pr" "🛑 smallhours could not auto-fix the failing CI.

**Reason:** ${reason}

_${work}_"
  exit 4
}

main() {
  [ "$#" -ge 2 ] || sh_die "usage: auto-fix.sh <pr-number> <attempt> [ci-run-id]"
  local pr="$1" attempt="$2" run_id="${3:-}" repo head issue cap
  repo="$(sh_repo)"
  sh_require_auth
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || sh_die "CLAUDE_CODE_OAUTH_TOKEN not set"
  config_load || sh_die "unreadable .smallhours.yml — refusing to run on defaults"
  cap="$(config_attempt_cap)"

  # Defensive gates, same posture as state-manager: automation-owned + open.
  if ! gh pr view "$pr" --repo "$repo" --json labels --jq '.labels[].name' \
       | grep -Fxq "$(label_for agent)"; then
    sh_log "auto-fix: PR #$pr not \`agent\`-owned — ignoring"
    exit 0
  fi
  if [ "$(gh pr view "$pr" --repo "$repo" --json state --jq .state)" != "OPEN" ]; then
    sh_log "auto-fix: PR #$pr is not OPEN — ignoring"
    exit 0
  fi

  head="$(gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName)"
  issue="$(sh_issue_from_pr "$pr")"

  # Work on the PR head branch.
  git fetch --quiet origin "$head"
  git checkout -B "$head" "origin/$head"

  # Context: which checks failed, plus the failed-job log tail when readable.
  # All of this is enrichment — a missing piece degrades, never aborts.
  local ctx prompt checks; ctx="$(mktemp)"; prompt="$(mktemp)"
  # gh pr checks exits non-zero when checks are failing (they are, here) —
  # capture first so that can't abort or double-print.
  checks="$(gh pr checks "$pr" --repo "$repo" 2>/dev/null || true)"
  {
    gh pr view "$pr" --repo "$repo" --json title,number \
      --jq '"Pull request #\(.number): \(.title)"'
    printf '\nCI is red. This is auto-fix attempt %s of %s (at %s the system hands off to a human).\n' \
      "$attempt" "$cap" "$cap"
    printf '\nFailing checks:\n'
    if [ -n "$checks" ]; then
      printf '%s\n' "$checks" | awk -F'\t' '$2 == "fail" { print "- " $1 }'
    else
      printf '(could not list checks)\n'
    fi
    if [ -n "$run_id" ]; then
      printf '\nLog tail of the failed CI jobs (last %s bytes):\n\n' "$_LOG_TAIL_BYTES"
      gh run view "$run_id" --repo "$repo" --log-failed 2>/dev/null \
        | tail -c "$_LOG_TAIL_BYTES" \
        || printf '(logs not readable with this token — go by the check names and run the suite locally)\n'
    fi
  } > "$ctx"
  sh_render_prompt "$_dir/../prompts/auto-fix.md" "$ctx" "$prompt"

  if ! claude_run auto_fix "$prompt" "$RESULT_JSON"; then
    local reason; reason="$(claude_result_text "$RESULT_JSON")"
    [ -n "$reason" ] || reason="the agent run failed before producing a result (see workflow logs)"
    rm -f "$ctx" "$prompt"
    _give_up "$pr" "$issue" "$reason"
  fi
  rm -f "$ctx" "$prompt"

  git add -A
  if git diff --cached --quiet; then
    # Nothing to push means CI never re-fires: treat as a hand-off, not a wait.
    local said; said="$(claude_result_text "$RESULT_JSON")"
    [ -n "$said" ] || said="(no summary)"
    _give_up "$pr" "$issue" "the agent made no changes, so there is nothing to re-run CI on. Its summary: ${said}"
  fi
  git -c user.name="smallhours" -c user.email="noreply@smallhours" \
    commit -m "smallhours: auto-fix CI attempt ${attempt} on #${pr}" --quiet
  git push origin "$head"

  sh_log "auto-fix: attempt $attempt pushed to $head — CI will re-run"
}

main "$@"
