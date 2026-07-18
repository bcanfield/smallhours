#!/usr/bin/env bash
# open-pr.sh — the DETERMINISTIC tail of T1. Never model-dependent: given a
# branch and its issue, it decides purely on whether commits exist.
#
#   open-pr.sh <issue-number> [branch] [attempt]
#
#   commits ahead of base   -> draft PR (label `agent`, "Closes #N"); if a PR
#                              already exists for the branch, adopt it (draft +
#                              `agent`) — the branch-but-no-PR fallback.
#   no commits              -> issue ready-for-human + comment; NO ghost PR.
#
# Prints the PR number on stdout when a PR exists/was created (empty otherwise).
# Env: GH_TOKEN, GITHUB_REPOSITORY. Runs inside a checked-out clone.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"

main() {
  [ "$#" -ge 1 ] || sh_die "usage: open-pr.sh <issue-number> [branch] [attempt]"
  local issue="$1" branch="${2:-}" attempt="${3:-1}" repo base
  repo="$(sh_repo)"
  sh_require_auth
  [ -n "$branch" ] || branch="$(sh_agent_branch "$issue" "$attempt")"
  base="$(sh_default_branch)"

  git fetch --quiet origin "$base" "$branch" 2>/dev/null || git fetch --quiet origin "$base"

  # Commits on the branch that aren't on base.
  local ahead=0
  if git rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    ahead="$(git rev-list --count "origin/$base..origin/$branch" 2>/dev/null || echo 0)"
  fi

  if [ "$ahead" -eq 0 ]; then
    sh_log "open-pr: no commits on $branch — no PR, handing to a human"
    state_set_issue "$issue" ready-for-human
    sh_comment_issue "$issue" \
      "🙅 smallhours produced no changes for this issue, so there is nothing to open a pull request with. Handing back for a human to look at."
    exit 0
  fi

  # Adopt an existing PR if one is already open for this branch (fallback for a
  # prior run that pushed but died before opening the PR).
  local pr
  pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [ -n "$pr" ]; then
    sh_log "open-pr: adopting existing PR #$pr for $branch"
    gh pr ready --repo "$repo" --undo "$pr" >/dev/null 2>&1 || true   # ensure draft
    state_pr_add_label "$pr" agent
  else
    local title; title="$(gh issue view "$issue" --repo "$repo" --json title --jq .title)"
    pr="$(gh pr create --repo "$repo" \
      --draft --head "$branch" --base "$base" \
      --title "$title" \
      --body "Closes #${issue}

_Opened by smallhours. This PR is automation-owned (\`agent\`) and stays a draft until CI is green._" \
      --label agent \
      | grep -oE '[0-9]+$' | tail -1)"
    sh_log "open-pr: created draft PR #$pr for $branch"
  fi

  printf '%s\n' "$pr"
}

main "$@"
