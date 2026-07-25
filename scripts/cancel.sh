#!/usr/bin/env bash
# cancel.sh — the give-up / cancellation transitions.
#
#   cancel.sh issue-closed  <issue-number>   # T10: issue closed mid-run
#   cancel.sh label-removed <issue-number>   # T11: state label removed mid-run
#   cancel.sh pr-closed     <pr-number>      # T9:  PR closed unmerged
#
# T10/T11: close the open agent draft PR, comment, delete its branch.
# T9:      the PR's issue -> ready-for-human + comment.
#
# NOTE (finding for M3/M4): T9 needs a `pull_request: [closed]` trigger, which
# the Phase-1 stub does not yet declare. cancel.sh implements the logic; the
# wiring is a routing task.
# Env: GH_TOKEN, GITHUB_REPOSITORY.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"

# Close the open agent PR for an issue (if any) and delete its branch.
_close_agent_pr_for_issue() { # issue-number reason
  local issue="$1" reason="$2" repo pr head
  repo="$(sh_repo)"
  # Find an open PR whose head branch is this issue's agent branch family.
  pr="$(gh pr list --repo "$repo" --state open --label "$(label_for agent)" \
        --json number,headRefName \
        --jq "[.[] | select(.headRefName | test(\"^agent/issue-${issue}(-r[0-9]+)?$\"))] | .[0].number" 2>/dev/null || true)"
  [ -n "$pr" ] || { sh_log "cancel: no open agent PR for issue #$issue"; return 0; }

  head="$(gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName)"
  gh pr comment "$pr" --repo "$repo" --body "🚫 ${reason} — closing this automation PR and deleting its branch."
  gh pr close "$pr" --repo "$repo" --delete-branch >/dev/null 2>&1 \
    || { gh pr close "$pr" --repo "$repo" >/dev/null; git push origin --delete "$head" 2>/dev/null || true; }
  sh_log "cancel: closed PR #$pr, deleted $head"
}

main() {
  [ "$#" -eq 2 ] || sh_die "usage: cancel.sh <issue-closed|label-removed|pr-closed> <number>"
  local mode="$1" num="$2"
  sh_require_auth

  case "$mode" in
    issue-closed)   # T10 — issue already closed by the maintainer.
      _close_agent_pr_for_issue "$num" "issue #$num was closed while smallhours was working on it"
      ;;
    label-removed)  # T11 — trigger label pulled mid-run.
      _close_agent_pr_for_issue "$num" "the state label was removed from issue #$num mid-run"
      # The issue is now state-less; ready-for-human keeps the exactly-one
      # invariant and matches "any give-up exit -> ready-for-human".
      state_set_issue "$num" ready-for-human
      sh_comment_issue "$num" "↩️ smallhours stopped because its state label was removed. Marked \`$(label_for ready-for-human)\`."
      ;;
    pr-closed)      # T9 — PR closed without merging.
      local issue; issue="$(sh_issue_from_pr "$num")"
      if [ -n "$issue" ]; then
        state_set_issue "$issue" ready-for-human
        sh_comment_issue "$issue" "🚪 The pull request for this issue (#$num) was closed without merging. Handing back to a human."
      else
        sh_log "cancel: could not resolve an issue for PR #$num"
      fi
      ;;
    *)
      sh_die "unknown mode: $mode"
      ;;
  esac
}

main "$@"
