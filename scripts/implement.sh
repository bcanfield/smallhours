#!/usr/bin/env bash
# implement.sh — T1 body. Branch, run the implement prompt, capture the work.
# The deterministic PR-opening is open-pr.sh; this script never opens a PR.
#
#   implement.sh <issue-number> [attempt]
#
# attempt (default 1) selects the branch: agent/issue-N, then -r2, -r3, … on
# retries (fresh branch each time — never force-push seen history).
#
# On a clean run: commits the working tree, pushes the branch, writes the Claude
# result JSON to $SMALLHOURS_RESULT_JSON for report-usage.sh, prints the branch.
# On give-up (Claude CLI failure): issue -> ready-for-human + reason, exit 4.
#
# Env: GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, GITHUB_REPOSITORY. Must run inside a
# checked-out clone of the consumer repo. Push identity must be the Fixer App
# (so the push re-triggers CI) — supplied by the caller's git credentials.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/claude-run.sh"

# Kept OUTSIDE the consumer working tree so `git add -A` never commits it.
RESULT_JSON="${SMALLHOURS_RESULT_JSON:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smallhours-result.json}"

main() {
  [ "$#" -ge 1 ] || sh_die "usage: implement.sh <issue-number> [attempt]"
  local issue="$1" attempt="${2:-1}" repo branch base
  repo="$(sh_repo)"
  sh_require_auth
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || sh_die "CLAUDE_CODE_OAUTH_TOKEN not set"
  config_load || sh_die "unreadable .smallhours.yml — refusing to run on defaults"

  branch="$(sh_agent_branch "$issue" "$attempt")"
  base="$(sh_default_branch)"

  # stdout is a machine value (the branch name) consumed by the caller. Git and
  # gh chatter must NOT leak into it (git's "branch '…' set up to track" line
  # once corrupted the captured branch). Save real stdout on fd 4, send
  # everything else to stderr; emit the branch on fd 4 at the end.
  exec 4>&1 1>&2

  # Coarse state; authorize.sh set this already, but keep implement.sh runnable
  # on its own (self-hosted portability contract).
  state_set_issue "$issue" agent-working

  # Fresh branch off the current base tip.
  git fetch --quiet origin "$base"
  git checkout -B "$branch" "origin/$base"

  # Build the prompt: template + issue context (jq quotes the body safely).
  local ctx prompt; ctx="$(mktemp)"; prompt="$(mktemp)"
  gh issue view "$issue" --repo "$repo" --json number,title,body \
    --jq '"Issue #\(.number): \(.title)\n\n\(.body // "(no description)")"' > "$ctx"
  sh_render_prompt "$_dir/../prompts/implement.md" "$ctx" "$prompt"

  # Run. claude_run returns non-zero on give-up (CLI error or is_error).
  if ! claude_run implement "$prompt" "$RESULT_JSON"; then
    local reason; reason="$(claude_result_text "$RESULT_JSON")"
    [ -n "$reason" ] || reason="the agent run failed before producing a result (see workflow logs)"
    state_set_issue "$issue" ready-for-human
    sh_comment_issue "$issue" \
      "🛑 smallhours could not implement this issue and is handing it back.

**Reason:** ${reason}"
    rm -f "$ctx" "$prompt"
    exit 4
  fi
  rm -f "$ctx" "$prompt"

  # Capture whatever the agent produced. It may have committed itself; if not,
  # commit the working tree so no work is lost. Either way the branch carries it.
  git add -A
  if ! git diff --cached --quiet; then
    git -c user.name="smallhours" -c user.email="noreply@smallhours" \
      commit -m "smallhours: implement #${issue}" --quiet
  fi

  # Push the branch (no-op-safe if nothing changed and it already exists).
  git push --set-upstream origin "$branch"

  sh_log "implement: branch $branch pushed"
  printf '%s\n' "$branch" >&4
}

main "$@"
