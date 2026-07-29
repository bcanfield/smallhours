#!/usr/bin/env bash
# implement.sh — T1 body. Branch, run the implement prompt, capture the work.
# The deterministic PR-opening is open-pr.sh; this script never opens a PR.
#
#   implement.sh <issue-number> [attempt]
#
# attempt selects the branch: agent/issue-N, then -r2, -r3, … on retries
# (fresh branch each time — never force-push seen history). When omitted it is
# DERIVED from the remote: one past the highest agent/issue-N[-rK] branch
# already minted, so a re-label after an earlier attempt never collides with a
# surviving branch (a plain re-run on a clean repo still gets attempt 1).
#
# On a clean run: commits the working tree, pushes the branch, writes the Claude
# result JSON to $SMALLHOURS_RESULT_JSON for report-usage.sh, prints the branch.
# On give-up (Claude CLI failure, or a rejected push — the work is committed
# but unreachable): issue -> ready-for-human + reason, exit 4.
#
# Env: GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, GITHUB_REPOSITORY. Must run inside a
# checked-out clone of the consumer repo. Push identity must be the Fixer App
# (so the push re-triggers CI) — supplied by the caller's git credentials.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/claude-run.sh"
. "$_dir/lib/tracker-context.sh"
. "$_dir/lib/sweep.sh"

# Kept OUTSIDE the consumer working tree so `git add -A` never commits it.
RESULT_JSON="${SMALLHOURS_RESULT_JSON:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smallhours-result.json}"

_give_up() { # issue reason
  local issue="$1" reason="$2" work
  work="$(claude_work_summary "${RESULT_JSON}.work")"
  state_set_issue "$issue" ready-for-human
  sh_comment_issue "$issue" "🛑 smallhours could not implement this issue and is handing it back.

**Reason:** ${reason}

_${work}_"
  exit 4
}

# Commit the working tree onto the current branch and push it. Used by BOTH the
# clean path and the wall-clock give-up (ADR 0007) — a timed-out run is the one
# give-up whose partial work is worth keeping, because the agent was still
# making progress when the clock stopped it.
#   0  branch carries commits and reached the remote
#   1  nothing to capture (empty working tree, no commits ahead of base)
#   2  push rejected; git's text is in $_SH_PUSH_ERR
# Skipping the push at 0-commits keeps empty refs off the remote; open-pr.sh
# reads the same "no commits" and hands back either way.
_SH_PUSH_ERR=""
_capture_work() { # issue branch base
  local issue="$1" branch="$2" base="$3"
  git add -A
  if ! git diff --cached --quiet; then
    git -c user.name="smallhours" -c user.email="noreply@smallhours" \
      commit -m "smallhours: implement #${issue}" --quiet
  fi
  [ "$(git rev-list --count "origin/${base}..HEAD" 2>/dev/null || echo 0)" -gt 0 ] || return 1
  _SH_PUSH_ERR=""
  _SH_PUSH_ERR="$(sh_push --set-upstream origin "$branch")" || return 2
  return 0
}

main() {
  [ "$#" -ge 1 ] || sh_die "usage: implement.sh <issue-number> [attempt]"
  local issue="$1" attempt="${2:-}" repo branch base
  repo="$(sh_repo)"
  sh_require_auth
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || sh_die "CLAUDE_CODE_OAUTH_TOKEN not set"
  config_load || sh_die "unreadable .smallhours.yml — refusing to run on defaults"

  if [ -z "$attempt" ]; then
    attempt="$(git ls-remote --heads origin "agent/issue-${issue}*" \
                 | awk '{print $2}' | sed 's#^refs/heads/##' \
                 | sweep_next_attempt "$issue")"
  fi
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

  # Build the prompt: template + issue context (jq quotes the body safely),
  # then the deterministic tracker-context pre-step (ADR 0006 / 06-4): parent
  # spec inlined verbatim + one line per cleared blocker. Enrichment only —
  # its failure never fails the run.
  local ctx prompt ijson bodyf
  ctx="$(mktemp)"; prompt="$(mktemp)"; ijson="$(mktemp)"; bodyf="$(mktemp)"
  gh issue view "$issue" --repo "$repo" --json number,title,body > "$ijson"
  jq -r '"Issue #\(.number): \(.title)\n\n\(.body // "(no description)")"' "$ijson" > "$ctx"
  jq -r '.body // ""' "$ijson" > "$bodyf"
  tracker_context "$issue" "$bodyf" >> "$ctx" \
    || sh_log "tracker-context: enrichment failed — continuing with plain issue context"
  rm -f "$ijson" "$bodyf"
  sh_render_prompt "$_dir/../prompts/implement.md" "$ctx" "$prompt"

  # Run. claude_run returns non-zero on give-up (CLI error or is_error).
  if ! claude_run implement "$prompt" "$RESULT_JSON"; then
    local reason; reason="$(claude_give_up_reason "$RESULT_JSON" implement)"
    rm -f "$ctx" "$prompt"

    # Wall-clock give-up: keep the partial work as a BRANCH, never a pull
    # request. A draft PR would trigger consumer CI, and a red CI on an `agent`
    # PR feeds the auto-fix loop — which would then spend up to attempt_cap
    # further runs trying to green a half-implemented change. A bare branch is
    # inert: state-manager finds no PR for it and does nothing (ADR 0007).
    if [ "$(claude_result_field "$RESULT_JSON" '.subtype')" = "error_timeout" ]; then
      local cap_rc=0
      _capture_work "$issue" "$branch" "$base" || cap_rc=$?
      case "$cap_rc" in
        0) sh_log "implement: partial work pushed to $branch after wall-clock give-up"
           reason="${reason}

The partial work is committed on \`${branch}\` — no pull request, because it is unfinished and opening one would start CI and the auto-fix loop on a half-implemented change. Nothing on that branch has been reviewed or tested." ;;
        1) sh_log "implement: wall-clock give-up with an empty working tree — nothing to push" ;;
        *) sh_log "implement: wall-clock give-up and the push was rejected too"
           reason="${reason}

The partial work could not be saved: the push to \`${branch}\` was rejected.

\`\`\`
${_SH_PUSH_ERR}
\`\`\`" ;;
      esac
    fi

    _give_up "$issue" "$reason"
  fi
  rm -f "$ctx" "$prompt"

  # Capture whatever the agent produced. It may have committed itself; if not,
  # commit the working tree so no work is lost. Either way the branch carries
  # it. A rejected push is a give-up like any other: the work is committed but
  # unreachable, and no retry of this branch will ever clear it.
  local cap_rc=0
  _capture_work "$issue" "$branch" "$base" || cap_rc=$?
  if [ "$cap_rc" -eq 2 ]; then
    _give_up "$issue" "the work was committed but the push to \`${branch}\` was rejected, so nothing reached the remote and no pull request can open:

\`\`\`
${_SH_PUSH_ERR}
\`\`\`"
  fi

  sh_log "implement: branch $branch pushed"
  printf '%s\n' "$branch" >&4
}

main "$@"
