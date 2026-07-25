#!/usr/bin/env bash
# state-manager.sh — CI outcome -> PR/issue state (T2 / T3, Phase 1).
#
#   state-manager.sh <pr-number> <ci-conclusion>
#   ci-conclusion: success | failure  (from the consumer CI workflow_run)
#
#   success + mergeStateStatus CLEAN -> PR ready + `ready-to-merge`; issue in-review  (T2)
#   success + UNKNOWN                -> do nothing; a later event/sweep retries
#   success + other (BEHIND/…)       -> leave draft (Phase 1 has no sweep) — logged
#   failure                          -> PR draft + `ci-failing`; issue ready-for-human (T3)
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

  # Defensive gate: only automation-owned PRs.
  if ! gh pr view "$pr" --repo "$repo" --json labels --jq '.labels[].name' \
       | grep -Fxq "$(label_for agent)"; then
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
    sh_log "state-manager: CI red on PR #$pr (T3)"
    state_pr_add_label "$pr" ci-failing
    if [ -n "$issue" ]; then
      state_set_issue "$issue" ready-for-human
      sh_comment_issue "$issue" \
        "🔴 CI is failing on #${pr} and smallhours does not self-heal in Phase 1. Handing back to a human. (Phase 2 will attempt an auto-fix here.)"
    fi
    exit 0
  fi

  # ci == success
  local merge; merge="$(gh pr view "$pr" --repo "$repo" --json mergeStateStatus --jq .mergeStateStatus)"
  case "$merge" in
    CLEAN)
      sh_log "state-manager: CI green + CLEAN on PR #$pr (T2) -> ready"
      gh pr ready --repo "$repo" "$pr" >/dev/null
      state_pr_remove_label "$pr" ci-failing
      state_pr_add_label "$pr" ready-to-merge
      [ -n "$issue" ] && state_set_issue "$issue" in-review
      ;;
    UNKNOWN)
      sh_log "state-manager: mergeStateStatus UNKNOWN on PR #$pr — doing nothing, will retry"
      ;;
    *)
      # Green but not mergeable (BEHIND/BLOCKED/DIRTY/UNSTABLE). Phase 1 has no
      # sweep to reconcile this, so leave the PR a draft rather than call a
      # non-CLEAN PR "ready". Phase 2's sweep (T5/T6) closes this gap.
      sh_log "state-manager: CI green but mergeStateStatus=$merge on PR #$pr — staying draft (Phase 1 gap; Phase 2 sweep handles)"
      state_pr_remove_label "$pr" ci-failing
      ;;
  esac
}

main "$@"
