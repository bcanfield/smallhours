#!/usr/bin/env bash
# resolve-conflict.sh — T6 body. The sweep found an agent PR whose branch is
# DIRTY (merge conflict with base): put the PR back in draft, start a merge of
# base into the PR branch, let the agent resolve the conflicts, then commit the
# merge and push — the push re-runs CI, which routes the outcome back through
# state-manager (green -> T2, red -> the auto-fix loop).
#
#   resolve-conflict.sh <pr-number>
#
# Give-up (Claude CLI failure, or conflicts left unresolved): abort the merge,
# PR `human-needed`, issue ready-for-human + reason, exit 4.
# Env: GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, GITHUB_REPOSITORY. Runs in a clone.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/claude-run.sh"

# Kept OUTSIDE the consumer working tree so `git add -A` never commits it.
RESULT_JSON="${SMALLHOURS_RESULT_JSON:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smallhours-result.json}"

_give_up() { # pr issue reason
  local pr="$1" issue="$2" reason="$3" work
  work="$(claude_work_summary "${RESULT_JSON}.work")"
  git merge --abort 2>/dev/null || true
  state_pr_add_label "$pr" human-needed
  [ -n "$issue" ] && state_set_issue "$issue" ready-for-human
  sh_comment_pr "$pr" "🛑 smallhours could not resolve this branch's merge conflict with base.

**Reason:** ${reason}

_${work}_"
  exit 4
}

main() {
  [ "$#" -eq 1 ] || sh_die "usage: resolve-conflict.sh <pr-number>"
  local pr="$1" repo head base issue
  repo="$(sh_repo)"
  sh_require_auth
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || sh_die "CLAUDE_CODE_OAUTH_TOKEN not set"
  config_load || sh_die "unreadable .smallhours.yml — refusing to run on defaults"

  # Defensive gates, same posture as auto-fix: automation-owned + open + same-repo.
  local pj
  pj="$(gh pr view "$pr" --repo "$repo" \
          --json state,headRefName,baseRefName,isCrossRepository,labels)"
  if ! jq -r '.labels[].name' <<< "$pj" | grep -Fxq "$(label_for agent)"; then
    sh_log "resolve-conflict: PR #$pr not \`agent\`-owned — ignoring"
    exit 0
  fi
  if [ "$(jq -r .state <<< "$pj")" != "OPEN" ]; then
    sh_log "resolve-conflict: PR #$pr is not OPEN — ignoring"
    exit 0
  fi
  if [ "$(jq -r .isCrossRepository <<< "$pj")" = "true" ]; then
    sh_log "resolve-conflict: PR #$pr has a cross-repository head — ignoring"
    exit 0
  fi
  head="$(jq -r .headRefName <<< "$pj")"
  base="$(jq -r .baseRefName <<< "$pj")"
  issue="$(sh_issue_from_pr "$pr")"

  # T6: the PR goes back to draft while automation works; the issue returns to
  # its coarse working span (conflict-resolving is inside agent-working).
  gh pr ready --undo "$pr" --repo "$repo" >/dev/null 2>&1 || true
  state_pr_remove_label "$pr" ready-to-merge
  [ -n "$issue" ] && state_set_issue "$issue" agent-working

  git fetch --quiet origin "$base" "$head"
  git checkout -B "$head" "origin/$head"

  # Start the merge; a conflict is expected (that is why we are here). If it
  # merges cleanly (the DIRTY reading was stale), committing it is equivalent
  # to a T5 update — still worth pushing. NEVER swallow the merge output: when
  # this path misbehaves, git's own words are the only diagnostic (the same
  # lesson as the claude-run give-up stderr, v0.4.2).
  # Identity on the MERGE, not just the commit: git merge validates the
  # committer ident up front and hosted runners have none configured
  # ("fatal: empty ident name" — found live, first T6 run).
  local conflicted="" merge_out=""
  if ! merge_out="$(git -c user.name="smallhours" -c user.email="noreply@smallhours" \
                      merge --no-commit --no-ff "origin/$base" 2>&1)"; then
    printf '%s\n' "$merge_out" >&2
    conflicted="$(git diff --name-only --diff-filter=U)"
    # Second signal: unmerged index entries (belt and braces — a diff oddity
    # must not turn a resolvable conflict into a give-up).
    [ -n "$conflicted" ] || conflicted="$(git ls-files -u | awk '{print $4}' | sort -u)"
    if [ -z "$conflicted" ]; then
      sh_log "resolve-conflict: merge failed with no unmerged paths; git status:"
      git status --porcelain >&2 || true
      _give_up "$pr" "$issue" \
        "the merge of \`$base\` failed without leaving conflicts to resolve. Git said: $(printf '%s' "$merge_out" | tail -c 400)"
    fi
  else
    printf '%s\n' "$merge_out" >&2
    sh_log "resolve-conflict: merge of $base completed without conflicts (stale DIRTY reading) — pushing the update"
  fi

  if [ -n "$conflicted" ]; then
    local ctx prompt
    ctx="$(mktemp)"; prompt="$(mktemp)"
    {
      gh pr view "$pr" --repo "$repo" --json title,number \
        --jq '"Pull request #\(.number): \(.title)"'
      printf '\nA merge of the base branch `%s` into this branch is in progress and stopped on conflicts.\n' "$base"
      printf '\nConflicted files:\n'
      printf '%s\n' "$conflicted" | sed 's/^/- /'
    } > "$ctx"
    sh_render_prompt "$_dir/../prompts/resolve-conflict.md" "$ctx" "$prompt"

    if ! claude_run resolve_conflict "$prompt" "$RESULT_JSON"; then
      local reason; reason="$(claude_give_up_reason "$RESULT_JSON" resolve_conflict)"
      rm -f "$ctx" "$prompt"
      _give_up "$pr" "$issue" "$reason"
    fi
    rm -f "$ctx" "$prompt"

    # Anything still conflicted means the agent stopped (per its instructions)
    # or missed a file — either way a human must look; guessing strands CI.
    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
      local said; said="$(claude_result_text "$RESULT_JSON")"
      [ -n "$said" ] || said="(no summary)"
      _give_up "$pr" "$issue" "conflicts were left unresolved. The agent's summary: ${said}"
    fi
  fi

  # Complete the merge commit (unless the agent already committed it) and push.
  git add -A
  if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] || ! git diff --cached --quiet; then
    git -c user.name="smallhours" -c user.email="noreply@smallhours" \
      commit --no-edit -m "smallhours: merge ${base} into ${head} (resolve conflicts, #${pr})" --quiet
  fi
  # An unpushed merge leaves the PR reading DIRTY, so the next sweep tick
  # re-runs this whole stage against the same rejection, indefinitely.
  local push_err
  if ! push_err="$(sh_push origin "$head")"; then
    _give_up "$pr" "$issue" "the merge of \`${base}\` was completed but the push to \`${head}\` was rejected, so this pull request still conflicts with its base:

\`\`\`
${push_err}
\`\`\`"
  fi

  sh_log "resolve-conflict: merged $base into $head on PR #$pr — CI will re-run"
}

main "$@"
