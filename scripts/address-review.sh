#!/usr/bin/env bash
# address-review.sh — T7 re-summon. A FORMAL "Request changes" review from a
# write+ user sends the PR back to draft and re-runs the agent. Plain comments
# and non-write reviewers never trigger this (gated below).
#
#   address-review.sh <pr-number> <review-state> <reviewer-login>
#   review-state: the submitted review's state (only CHANGES_REQUESTED acts)
#
# Effect: PR -> draft; issue -> agent-working; run the address-review prompt;
# commit + push (re-triggers CI). Give-up -> issue ready-for-human, exit 4.
# Env: GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, GITHUB_REPOSITORY. Runs in a clone.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/claude-run.sh"

# Kept OUTSIDE the consumer working tree so `git add -A` never commits it.
RESULT_JSON="${SMALLHOURS_RESULT_JSON:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smallhours-result.json}"

# Case-insensitive equality for the review-state token.
_eq_ci() { [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$2" ]; }

main() {
  [ "$#" -eq 3 ] || sh_die "usage: address-review.sh <pr-number> <review-state> <reviewer-login>"
  local pr="$1" rstate="$2" reviewer="$3" repo perm head issue
  repo="$(sh_repo)"
  sh_require_auth
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || sh_die "CLAUDE_CODE_OAUTH_TOKEN not set"
  config_load || sh_die "unreadable .smallhours.yml — refusing to run on defaults"

  # Gate 1: only a formal changes-requested review acts.
  if ! _eq_ci "$rstate" "changes_requested"; then
    sh_log "address-review: review state '$rstate' is not changes_requested — ignoring"
    exit 0
  fi
  # Gate 2: only automation-owned PRs.
  if ! gh pr view "$pr" --repo "$repo" --json labels --jq '.labels[].name' \
       | grep -Fxq "$(label_for agent)"; then
    sh_log "address-review: PR #$pr not \`agent\`-owned — ignoring"
    exit 0
  fi
  # Gate 3: reviewer must have write+.
  perm="$(gh api "repos/$repo/collaborators/$reviewer/permission" --jq .permission 2>/dev/null || echo none)"
  case "$perm" in
    admin|maintain|write) : ;;
    *) sh_log "address-review: reviewer $reviewer has '$perm' — ignoring"; exit 0 ;;
  esac

  head="$(gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName)"
  issue="$(sh_issue_from_pr "$pr")"

  # Back to draft; issue back to working.
  gh pr ready --repo "$repo" --undo "$pr" >/dev/null
  state_pr_remove_label "$pr" ready-to-merge
  [ -n "$issue" ] && state_set_issue "$issue" agent-working

  # Work on the PR head branch.
  git fetch --quiet origin "$head"
  git checkout -B "$head" "origin/$head"

  # Context: the latest changes-requested review body + inline review comments.
  local ctx prompt; ctx="$(mktemp)"; prompt="$(mktemp)"
  {
    gh pr view "$pr" --repo "$repo" --json title,number \
      --jq '"Pull request #\(.number): \(.title)"'
    printf '\nRequested changes:\n\n'
    gh pr view "$pr" --repo "$repo" --json reviews \
      --jq '[.reviews[] | select(.state=="CHANGES_REQUESTED")] | last | .body // "(no summary)"'
    printf '\nInline comments:\n'
    gh api "repos/$repo/pulls/$pr/comments" \
      --jq '.[] | "- \(.path):\(.line // .original_line // "?") — \(.body)"' 2>/dev/null || true
  } > "$ctx"
  sh_render_prompt "$_dir/../prompts/address-review.md" "$ctx" "$prompt"

  if ! claude_run address_review "$prompt" "$RESULT_JSON"; then
    local reason work; reason="$(claude_result_text "$RESULT_JSON")"
    [ -n "$reason" ] || reason="the agent run failed before producing a result (see workflow logs)"
    work="$(claude_work_summary "${RESULT_JSON}.work")"
    [ -n "$issue" ] && state_set_issue "$issue" ready-for-human
    sh_comment_pr "$pr" "🛑 smallhours could not address the requested changes.

**Reason:** ${reason}

_${work}_"
    rm -f "$ctx" "$prompt"
    exit 4
  fi
  rm -f "$ctx" "$prompt"

  git add -A
  if ! git diff --cached --quiet; then
    git -c user.name="smallhours" -c user.email="noreply@smallhours" \
      commit -m "smallhours: address review on #${pr}" --quiet
  fi
  git push origin "$head"

  sh_log "address-review: pushed revisions to $head"
}

main "$@"
