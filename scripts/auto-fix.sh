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
# Give-up (Claude CLI failure, or a run that left nothing for CI to re-fire on):
# PR `human-needed`, issue ready-for-human + reason, exit 4.
#
# A CLEAN WORKING TREE IS NOT A GIVE-UP BY ITSELF (ADR 0009). Some repairs are
# not commits — a PR title on a squash-merging repo is the observed one — so the
# stage snapshots the pull request before the agent runs and diffs it after:
# CI moving is a repair, a title change with no CI behind it is a nameable
# hand-off, and only a PR that did not move at all is the old "made no changes".
# Env: GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, GITHUB_REPOSITORY. Runs in a clone.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/claude-run.sh"
. "$_dir/lib/autofix.sh"

# Kept OUTSIDE the consumer working tree so `git add -A` never commits it.
RESULT_JSON="${SMALLHOURS_RESULT_JSON:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smallhours-result.json}"

# Cap the inlined log tail — failed E2E logs can be enormous.
_LOG_TAIL_BYTES=20000

# How long to wait for CI to re-fire after an out-of-tree repair, and how often
# to look. Not consumer-tunable, same posture as the wall-clock budget (ADR
# 0007): the number is about GitHub's event latency, which a consumer has no
# better view of than the toolkit does. Two minutes is generous against the
# observed lag between a `pull_request: edited` and its queued run, and the only
# thing it costs when the wait is futile is two minutes of the job that was
# about to hand off to a human anyway.
# Env-overridable so the tests can drive the stranded path without sleeping —
# same testing seam as SMALLHOURS_RESULT_JSON / SMALLHOURS_WATCHDOG_MINUTES.
# NOT a consumer knob: it is deliberately absent from `.smallhours.yml`.
_REFIRE_WAIT_SECONDS="${SMALLHOURS_REFIRE_WAIT_SECONDS:-120}"
_REFIRE_POLL_SECONDS="${SMALLHOURS_REFIRE_POLL_SECONDS:-10}"

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

# The three fields the clean-tree decision is made from, in one call.
_pr_snapshot() { # pr -> {title, body, statusCheckRollup}
  gh pr view "$1" --repo "$(sh_repo)" --json title,body,statusCheckRollup
}

# The agent left the working tree clean. That is NOT proof it did nothing (#30,
# ADR 0009): the repair may live outside the tree. Decide by diffing the pull
# request against the pre-run snapshot — never by trusting the agent's own
# account, which the toolkit cannot check. NEVER RETURNS.
_clean_tree() { # pr issue attempt snapshot-before
  local pr="$1" issue="$2" attempt="$3" before="$4" repo
  repo="$(sh_repo)"

  local before_title before_body before_digest
  before_title="$(jq -r '.title // ""' <<< "$before")"
  before_body="$(jq -r  '.body  // ""' <<< "$before")"
  before_digest="$(jq -c '.statusCheckRollup // []' <<< "$before" | autofix_checks_digest)"

  local now now_title now_body now_digest pending retitled outcome waited=0
  now="$(_pr_snapshot "$pr")"

  # The body is off-limits to the agent (prompts/auto-fix.md): it carries
  # `Closes #N`, which is what closes the issue when the PR merges. Restoring it
  # costs one API call in a case that should never happen, and makes the
  # prompt's rule an invariant instead of a request — this whole issue is about
  # what a prompt rule is worth when the environment permits otherwise.
  now_body="$(jq -r '.body // ""' <<< "$now")"
  if [ "$now_body" != "$before_body" ]; then
    sh_log "auto-fix: the agent edited the PR body — restoring the pre-run text"
    gh pr edit "$pr" --repo "$repo" --body "$before_body" >/dev/null 2>&1 \
      || sh_log "auto-fix: could not restore the PR body"
  fi

  # A retitle re-runs CI only where the consumer's workflow triggers on
  # `pull_request: edited`, and even there the run takes a moment to appear. So
  # `stranded` is a verdict to re-ask, not to act on, until the window closes.
  while :; do
    now_title="$(jq -r '.title // ""' <<< "$now")"
    now_digest="$(jq -c '.statusCheckRollup // []' <<< "$now" | autofix_checks_digest)"
    pending="$(jq -c '.statusCheckRollup // []' <<< "$now" | autofix_checks_pending)"
    if [ "$now_title" = "$before_title" ]; then retitled=false; else retitled=true; fi
    outcome="$(autofix_clean_tree_outcome "$retitled" \
                 "$(autofix_ci_moved "$before_digest" "$now_digest" "$pending")")"
    [ "$outcome" = "stranded" ] || break
    [ "$waited" -lt "$_REFIRE_WAIT_SECONDS" ] || break
    sh_log "auto-fix: title repaired but no CI yet — waiting (${waited}s of ${_REFIRE_WAIT_SECONDS}s)"
    sleep "$_REFIRE_POLL_SECONDS"
    waited=$(( waited + _REFIRE_POLL_SECONDS ))
    now="$(_pr_snapshot "$pr")"
  done

  local said; said="$(claude_result_text "$RESULT_JSON")"
  [ -n "$said" ] || said="(no summary)"

  case "$outcome" in
    out-of-tree)
      # No commit, but the pull request moved and CI is live again. Say so on
      # the timeline: the attempt label is about to be the only trace of this
      # run, and a spent attempt with no explanation is what sends the next
      # reader to the Actions tab.
      local what
      if [ "$retitled" = "true" ]; then
        what="the pull request title — now \`${now_title}\`"
      else
        what="something outside the working tree"
      fi
      sh_comment_pr "$pr" "🔧 Auto-fix attempt ${attempt} repaired ${what}. No commit was needed, so there is nothing to push — CI is running again and the normal flow resumes from its result.

_${said}_"
      sh_log "auto-fix: attempt $attempt repaired out of tree — CI is moving, handing back to the CI path"
      exit 0
      ;;
    stranded)
      _give_up "$pr" "$issue" "the agent repaired this outside the working tree — the pull request title is now \`${now_title}\` — but no CI run started in the ${_REFIRE_WAIT_SECONDS}s that followed, so nothing will ever re-check it. A retitle only re-runs CI on a workflow that triggers on \`pull_request: edited\`; this repository's does not appear to. The title itself is fixed. Its summary: ${said}"
      ;;
    *)
      _give_up "$pr" "$issue" "the agent made no changes, and nothing on the pull request moved either, so there is nothing to re-run CI on. Its summary: ${said}"
      ;;
  esac
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

  # Snapshot the pull request BEFORE the agent runs — _clean_tree diffs against
  # this to tell an out-of-tree repair from a run that achieved nothing. Also
  # feeds the prompt's title line, so it costs no extra API call.
  local snap; snap="$(_pr_snapshot "$pr")"

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
    printf 'Pull request #%s: %s\n' "$pr" "$(jq -r '.title // ""' <<< "$snap")"
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
    local reason; reason="$(claude_give_up_reason "$RESULT_JSON" auto_fix)"
    rm -f "$ctx" "$prompt"
    _give_up "$pr" "$issue" "$reason"
  fi
  rm -f "$ctx" "$prompt"

  git add -A
  if git diff --cached --quiet; then
    # An empty tree is a question, not a verdict — ask the pull request.
    _clean_tree "$pr" "$issue" "$attempt" "$snap"   # never returns
  fi
  git -c user.name="smallhours" -c user.email="noreply@smallhours" \
    commit -m "smallhours: auto-fix CI attempt ${attempt} on #${pr}" --quiet
  # Same reasoning as the no-changes branch above: an unpushed fix never
  # re-runs CI, so the PR would sit red forever waiting on a push that failed.
  local push_err
  if ! push_err="$(sh_push origin "$head")"; then
    _give_up "$pr" "$issue" "the fix was committed but the push to \`${head}\` was rejected, so CI will not re-run:

\`\`\`
${push_err}
\`\`\`"
  fi

  sh_log "auto-fix: attempt $attempt pushed to $head — CI will re-run"
}

main "$@"
