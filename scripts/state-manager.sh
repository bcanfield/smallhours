#!/usr/bin/env bash
# state-manager.sh — CI outcome -> PR/issue state (T2 / T3' / T4, Phase 2).
#
#   state-manager.sh <pr-number> <ci-conclusion>
#   ci-conclusion: success | failure  (from the consumer CI workflow_run)
#
#   success + mergeStateStatus CLEAN -> PR ready + `ready-to-merge`; issue in-review  (T2)
#   success + UNKNOWN                -> attempt labels stripped, else nothing; retried later
#   success + other (BEHIND/…)       -> leave draft (Phase 1 has no sweep) — logged
#   failure, attempts < attempt_cap  -> attempt N+1: label autofix-attempt-N+1,
#                                       issue stays agent-working, decision
#                                       `autofix=N+1` printed for the caller to
#                                       summon auto-fix.sh                     (T3')
#   failure, attempts >= attempt_cap -> PR `human-needed`; issue ready-for-human
#                                       + reason comment                       (T4)
#
# stdout is a machine value: `autofix=<attempt>` when the caller should run the
# auto-fix stage, nothing otherwise. All logging goes to stderr (fd-4 isolation,
# same contract as implement.sh).
#
# The workflow hard-gates same-repo head + `agent` label before calling this;
# this script re-checks `agent` defensively (never act on a human PR).
# Env: GH_TOKEN, GITHUB_REPOSITORY.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"

main() {
  [ "$#" -eq 2 ] || sh_die "usage: state-manager.sh <pr-number> <success|failure>"
  local pr="$1" ci="$2" repo issue
  repo="$(sh_repo)"
  sh_require_auth

  # stdout carries only the machine decision; everything else -> stderr.
  exec 4>&1 1>&2

  # Defensive gate: only automation-owned PRs.
  local labels
  labels="$(gh pr view "$pr" --repo "$repo" --json labels --jq '.labels[].name')"
  if ! printf '%s\n' "$labels" | grep -Fxq "$(label_for agent)"; then
    sh_log "state-manager: PR #$pr has no \`agent\` label — not ours, ignoring"
    exit 0
  fi

  local state; state="$(gh pr view "$pr" --repo "$repo" --json state --jq .state)"
  if [ "$state" != "OPEN" ]; then
    sh_log "state-manager: PR #$pr is $state, not OPEN — ignoring"
    exit 0
  fi

  issue="$(sh_issue_from_pr "$pr")"

  if [ "$ci" = "failure" ]; then
    state_pr_add_label "$pr" ci-failing
    # A red PR must never carry ready-to-merge (re-run gone red after a T2).
    state_pr_remove_label "$pr" ready-to-merge

    local cap attempts
    cap="$(config_attempt_cap)"
    attempts="$(printf '%s\n' "$labels" | state_autofix_attempt_from_labels)"

    if [ "$attempts" -ge "$cap" ]; then
      # T4 — the cap-th consecutive fix also failed. Idempotent: a re-red on an
      # already-handed-off PR (e.g. a human rescue push that stays red) must
      # not re-comment.
      if printf '%s\n' "$labels" | grep -Fxq "$(label_for human-needed)"; then
        sh_log "state-manager: PR #$pr already handed off (human-needed) — T4 no-op"
        exit 0
      fi
      sh_log "state-manager: CI red on PR #$pr after $attempts auto-fix attempts (cap $cap) — giving up (T4)"
      state_pr_add_label "$pr" human-needed
      if [ -n "$issue" ]; then
        state_set_issue "$issue" ready-for-human
        sh_comment_issue "$issue" \
          "🛑 CI is still red on #${pr} after ${attempts} consecutive auto-fix attempts (attempt_cap: ${cap}). smallhours is giving up and handing this to a human. The branch and PR are kept — any push that turns CI green resumes the normal flow."
      fi
      exit 0
    fi

    # T3' — summon auto-fix attempt N+1. The issue stays (or returns to)
    # agent-working: CI-fixing is inside its deliberately coarse span.
    local next=$((attempts + 1))
    sh_log "state-manager: CI red on PR #$pr — auto-fix attempt $next of $cap (T3')"
    state_autofix_set_attempt "$pr" "$next"
    [ -n "$issue" ] && state_set_issue "$issue" agent-working
    printf 'autofix=%s\n' "$next" >&4
    exit 0
  fi

  # ci == success — any green resets the consecutive-failure counter (DESIGN),
  # whatever the mergeability turns out to be.
  state_autofix_clear "$pr"

  local merge; merge="$(gh pr view "$pr" --repo "$repo" --json mergeStateStatus --jq .mergeStateStatus)"
  case "$merge" in
    CLEAN)
      sh_log "state-manager: CI green + CLEAN on PR #$pr (T2) -> ready"
      gh pr ready --repo "$repo" "$pr" >/dev/null
      state_pr_remove_label "$pr" ci-failing human-needed
      state_pr_add_label "$pr" ready-to-merge
      [ -n "$issue" ] && state_set_issue "$issue" in-review
      ;;
    UNKNOWN)
      sh_log "state-manager: mergeStateStatus UNKNOWN on PR #$pr — doing nothing, will retry"
      ;;
    *)
      # Green but not mergeable (BEHIND/BLOCKED/DIRTY/UNSTABLE). Phase 1 has no
      # sweep to reconcile this, so leave the PR a draft rather than call a
      # non-CLEAN PR "ready". Phase 2's sweep (T5/T6, M7) closes this gap.
      sh_log "state-manager: CI green but mergeStateStatus=$merge on PR #$pr — staying draft (M7 sweep handles)"
      state_pr_remove_label "$pr" ci-failing
      ;;
  esac
}

main "$@"
