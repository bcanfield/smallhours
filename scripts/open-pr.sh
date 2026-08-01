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
  # The PR title now depends on config (conventional_title_types), so a
  # present-but-broken config must abort rather than quietly title the PR the
  # old way — same posture as every other config-reading stage.
  config_load || sh_die "unreadable .smallhours.yml — refusing to run on defaults"
  [ -n "$branch" ] || branch="$(sh_agent_branch "$issue" "$attempt")"
  base="$(sh_default_branch)"

  # stdout is a machine value (the PR number). Keep git/gh chatter off it —
  # save real stdout on fd 4, everything else to stderr (see implement.sh).
  exec 4>&1 1>&2

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
    # The title is the issue's, plus a conventional-commit type when the
    # consumer configured a label -> type map. On a squash-merging repo this
    # subject becomes the release commit, so an unprefixed one fails the
    # commit-format check and costs an auto-fix attempt to correct (#30).
    # Unconfigured (the default), this is the issue title verbatim.
    local meta title; meta="$(gh issue view "$issue" --repo "$repo" --json title,labels)"
    title="$(jq -r '.labels[].name' <<< "$meta" \
             | config_pr_title "$(jq -r '.title' <<< "$meta")")"
    [ "$title" = "$(jq -r '.title' <<< "$meta")" ] \
      || sh_log "open-pr: titled the PR '$title' from the issue's labels"
    # A verify gate that stayed red after its re-entries still gets pushed, so
    # say so on the PR. Silently shipping a known-red branch is worse than
    # having no gate — the reviewer would have no way to tell this apart from a
    # branch nobody checked.
    local gate="" vreport; vreport="$(sh_verify_report_path)"
    if [ -s "$vreport" ]; then
      local marker body headline
      marker="$(head -n 1 "$vreport")"
      body="$(tail -n +3 "$vreport")"
      case "$marker" in
        # The gate never started, so NOTHING here was checked — the opposite of
        # what a red-gate warning says. The remedy is the maintainer's, not the
        # agent's, and this is the surface they actually read. Deliberately
        # names no package manager: the fix is the same shape in every
        # ecosystem, and a node-flavoured example would read as inapplicable to
        # everyone else.
        could-not-run\ *)
          headline="⚠️ **The verify gate could not run, so this branch was not checked.**
\`${marker#could-not-run }\` did not resolve in the gate's shell. The gate runs your
\`verify:\` command through a login shell on a fresh runner, which sees only what
your shell startup files or the command itself put on \`PATH\` — a toolchain
installed for a single step during the run is not there any more.

Make the command resolve its own entry point (invoke it through a launcher the
runner always has, by absolute path, or via a bootstrap step inside the command)
and the gate will start checking this repo's work again. Until then CI is the
only thing looking at these changes.

The run log for this branch records what the gate could and could not see when
it looked for that command."
          sh_log "open-pr: PR body says the verify gate could not run"
          ;;
        *)
          headline="⚠️ **The verify gate was still failing when this branch was pushed.** smallhours
re-entered the agent to repair it and the command did not go green, so CI is the
next thing that will see it."
          sh_log "open-pr: PR body carries a red verify-gate report"
          ;;
      esac
      gate="

---

${headline}

<details><summary>Last output from the verify command</summary>

\`\`\`
${body}
\`\`\`

</details>"
    fi
    pr="$(gh pr create --repo "$repo" \
      --draft --head "$branch" --base "$base" \
      --title "$title" \
      --body "Closes #${issue}

_Opened by smallhours. This PR is automation-owned (\`agent\`) and stays a draft until CI is green._${gate}" \
      --label "$(label_for agent)" \
      | grep -oE '[0-9]+$' | tail -1)"
    sh_log "open-pr: created draft PR #$pr for $branch"
  fi

  printf '%s\n' "$pr" >&4
}

main "$@"
