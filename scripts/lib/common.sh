#!/usr/bin/env bash
# lib/common.sh — primitives shared by every stage script: repo resolution,
# logging, and GitHub comment helpers. Source this; do not execute.
#
# Portability: bash + gh only. The repo is read from GITHUB_REPOSITORY (set by
# GitHub Actions; a local caller or a future GitLab adapter sets it too), so no
# script hard-codes a repo or reaches into an Actions event payload.

[ -n "${_SMALLHOURS_COMMON_SH:-}" ] && return 0
_SMALLHOURS_COMMON_SH=1

sh_log()  { printf 'smallhours: %s\n' "$*" >&2; }
sh_die()  { printf 'smallhours: %s\n' "$*" >&2; exit 1; }

# owner/repo — GITHUB_REPOSITORY first (portable), else ask gh.
sh_repo() {
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '%s' "$GITHUB_REPOSITORY"
  else
    gh repo view --json nameWithOwner --jq .nameWithOwner
  fi
}

# Fail early with an actionable message if the auth contract isn't met. Accepts
# an env token (CI / the reusable workflow) OR gh's own login (a maintainer
# running a script by hand) — gh itself resolves either.
sh_require_auth() {
  [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] && return 0
  gh auth status >/dev/null 2>&1 && return 0
  sh_die "no GitHub auth — set GH_TOKEN/GITHUB_TOKEN or run 'gh auth login'"
}

sh_comment_issue() { # issue-number body
  gh issue comment "$1" --repo "$(sh_repo)" --body "$2"
}

sh_comment_pr() { # pr-number body
  gh pr comment "$1" --repo "$(sh_repo)" --body "$2"
}

# Cap the rejection text quoted back into a comment. GitHub's remote messages
# are a few lines; a pre-receive hook's can be a wall.
_SH_PUSH_ERR_BYTES=2000

# Push, and on failure hand the caller the reason instead of dying. Returns
# git's exit status; always mirrors git's stderr into the job log, and on
# failure ALSO prints the tail on stdout for the caller to quote in its
# give-up comment.
#
# Every stage that pushes must route failure into its own give-up path. A bare
# `git push` under `set -e` exits with nothing but a `##[error]`: no comment,
# no state transition, the issue stranded in agent-working on a branch that
# will never open a PR — which is exactly how mediamtx-connect#214 burned a
# full implement turn and then an hour of watchdog before anyone learned the
# App simply lacks `workflows` permission (smallhours#24). A rejection is a
# diagnosable failure exit, and DESIGN.md says those go in a comment.
#
# Our stdout is reserved for the reason alone. Redirection order matters:
# `>&2` binds git's stdout to the job log FIRST, then `2>"$err"` captures only
# git's stderr — so `--set-upstream`'s "branch … set up to track" chatter can
# neither be mistaken for a rejection nor corrupt the quoted text.
sh_push() { # git-push-args…
  local err rc=0
  err="$(mktemp)"
  git push "$@" >&2 2>"$err" || rc=$?
  cat "$err" >&2
  [ "$rc" -eq 0 ] || tail -c "$_SH_PUSH_ERR_BYTES" "$err"
  rm -f "$err"
  return "$rc"
}

# Repo default branch (the PR base, and the branch point for agent work).
sh_default_branch() {
  gh repo view "$(sh_repo)" --json defaultBranchRef --jq .defaultBranchRef.name
}

# Where implement.sh leaves a failed verify gate's output for open-pr.sh to
# quote in the PR body. A file rather than an argument because the two scripts
# are separate processes in the workflow step, and OUTSIDE the worktree so
# `git add -A` can never commit it. Absent = the gate passed, or none was
# configured; open-pr.sh must treat those the same way.
#
# FORMAT — a marker line, a blank line, then the output to quote:
#
#   red                      the gate ran and the checks failed
#   could-not-run <name>     <name> did not resolve, so the gate never started
#
# Two outcomes, two messages: only the first says anything about the agent's
# work, and a reader told "the gate failed" when nothing was ever checked has
# been told the opposite of the truth (#29).
sh_verify_report_path() {
  printf '%s\n' "${SMALLHOURS_VERIFY_REPORT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smallhours-verify-failed.txt}"
}

# Splice a context file into a prompt template at a lone `{{CONTEXT}}` line.
# Verbatim copy — no sed/eval — so arbitrary issue text can never be
# interpreted as shell or regex.
sh_render_prompt() { # template context_file out
  local template="$1" ctxfile="$2" out="$3" line
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "{{CONTEXT}}" ]; then
      cat "$ctxfile" >> "$out"
    else
      printf '%s\n' "$line" >> "$out"
    fi
  done < "$template"
}

# The issue an agent PR belongs to. Authoritative source is the branch name we
# mint (agent/issue-N or agent/issue-N-rK); falls back to a `Closes #N` in the
# body. Prints the number, or nothing if neither is present.
sh_issue_from_pr() { # pr-number
  local repo head body n; repo="$(sh_repo)"
  head="$(gh pr view "$1" --repo "$repo" --json headRefName --jq .headRefName 2>/dev/null || true)"
  n="$(printf '%s' "$head" | sed -n 's#^agent/issue-\([0-9]\{1,\}\).*#\1#p')"
  if [ -z "$n" ]; then
    body="$(gh pr view "$1" --repo "$repo" --json body --jq .body 2>/dev/null || true)"
    n="$(printf '%s' "$body" | grep -ioE 'closes #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
  fi
  printf '%s' "$n"
}

# Pure half, testable offline: does this issue already have an open agent PR?
# stdin is the head branch names of the open `agent` PRs, one per line.
#
# Same question implement_guard asks in the workflow, in the same shape — the
# point is that it can be asked a SECOND time from inside the per-issue
# concurrency group. The guard job carries no concurrency group, so its verdict
# is computed at event time while the `implement` job it gates queues behind
# `smallhours-issue-N`. mediamtx-connect#295 opened a second PR from that gap:
# guard said go at 22:22 with no PR in existence, implement started at 23:01
# holding a verdict 20 minutes older than the PR the first run had opened.
sh_has_agent_pr_for_issue() { # issue-number   (branch names on stdin)
  grep -Eq "^agent/issue-$1(-|$)"
}

# Branch name for an issue's agent work. Attempt 1 -> agent/issue-N;
# retries -> agent/issue-N-rK (fresh branch, never force-push seen history).
sh_agent_branch() { # issue-number [attempt]
  local n="$1" a="${2:-1}"
  if [ "$a" -le 1 ]; then printf 'agent/issue-%s' "$n"
  else printf 'agent/issue-%s-r%s' "$n" "$a"; fi
}
