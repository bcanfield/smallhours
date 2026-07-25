#!/usr/bin/env bash
# reeval.sh — green-gated T2 re-evaluation for ONE agent PR (M7).
#
#   reeval.sh <pr-number>
#
# Why this exists (debt phase1-green-not-clean-stranding, observed live on the
# first full T7 loop): an outstanding changes-requested review holds
# mergeStateStatus=BLOCKED at the moment the revision's green CI event runs
# state-manager, so T2 can never fire from the CI event alone — and the later
# approval/dismissal fires no workflow_run to retry. The workflow routes
# approved/dismissed reviews on agent PRs here; when the consumer CI's latest
# completed run on the head is green, state-manager re-decides (CLEAN -> T2).
# Red CI is left strictly alone — the auto-fix loop owns red.
# Env: GH_TOKEN, GITHUB_REPOSITORY.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/sweep.sh"

main() {
  [ "$#" -eq 1 ] || sh_die "usage: reeval.sh <pr-number>"
  local pr="$1" repo
  repo="$(sh_repo)"
  sh_require_auth

  # Defensive gates (the workflow gates too): automation-owned + open.
  if ! gh pr view "$pr" --repo "$repo" --json labels --jq '.labels[].name' \
       | grep -Fxq "$(label_for agent)"; then
    sh_log "reeval: PR #$pr has no \`agent\` label — not ours, ignoring"
    exit 0
  fi
  if [ "$(gh pr view "$pr" --repo "$repo" --json state --jq .state)" != "OPEN" ]; then
    sh_log "reeval: PR #$pr is not OPEN — ignoring"
    exit 0
  fi

  sweep_reeval_pr "$pr"
}

main "$@"
