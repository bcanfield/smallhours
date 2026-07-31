#!/usr/bin/env bash
# lib/verify.sh — the VERIFY GATE (CONTEXT.md). Runs the consumer's own command
# against the agent's work, and on a red result RE-ENTERS the same Claude session
# with its output. Source this; do not execute.
#
# Why it exists: an agent that cannot check its own work learns about a lint or
# type error from CI, minutes later, having already moved on — and pays one of
# only attempt_cap auto-fix attempts for it. Found here, the same error costs
# seconds and no attempt. This is the difference between a loop that self-corrects
# and one that ships its first draft.
#
# It NEVER fails the run. A gate still red after its re-entries pushes anyway, so
# CI and the auto-fix loop remain exactly the backstop they already were for
# consumers who set no `verify:` at all. The gate can make the loop faster; it
# cannot make it stricter, and it cannot stall an issue that would otherwise have
# reached review.
#
# RE-ENTRY, not retry: `attempt` is the CI auto-fix counter across jobs and
# `re-summon` is a requested-changes review across stages. This is a third loop
# and it lives inside one job — three loops, three words (CONTEXT.md).
#
# Depends on lib/config.sh (verify, verify_reentries), lib/claude-run.sh
# (claude_run) and lib/common.sh (sh_log).

[ -n "${_SMALLHOURS_VERIFY_SH:-}" ] && return 0
_SMALLHOURS_VERIFY_SH=1

_sh_v_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$_sh_v_dir/config.sh"
# shellcheck source=./claude-run.sh
. "$_sh_v_dir/claude-run.sh"
# shellcheck source=./common.sh
. "$_sh_v_dir/common.sh"

# Only the tail of the command's output is ever quoted — into the re-entry
# prompt and into the PR body. A failing suite can print megabytes and the
# useful part is the end; the agent still holds the change in its resumed
# context, so it does not need the whole log to know what it did.
SH_VERIFY_LOG_LINES="${SH_VERIFY_LOG_LINES:-200}"

# Set by verify_gate to the final red output, or empty when the gate passed or
# none was configured. implement.sh writes it to sh_verify_report_path for
# open-pr.sh to surface.
SH_VERIFY_FAILED=""

# verify_gate <result_json>
#   $1  the stage's result-JSON path; used only to derive sibling scratch paths
#       (the log, and one result file per re-entry).
# Always returns 0.
#
# Re-entry results go to their OWN files on purpose: report-usage.sh reads the
# stage's $RESULT_JSON, and overwriting it would replace the implement run's
# usage figures with a repair's.
verify_gate() { # result_json
  local base="$1"
  local cmd; cmd="$(config_verify)"
  if [ -z "$cmd" ]; then return 0; fi

  local max log i=0 rc=0
  max="$(config_verify_reentries)"
  log="${base}.verify"
  SH_VERIFY_FAILED=""

  while :; do
    rc=0
    # Runs the consumer's own scripts — which the agent just had the chance to
    # edit — and unlike the agent's Bash calls this is NOT inside the sandbox.
    # The tokens are the one thing worth withholding: the `.git/config`
    # credentials are load-bearing for the push and stay, but nothing a verify
    # command legitimately does needs GH_TOKEN.
    env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      bash -c "$cmd" > "$log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$i" -eq 0 ]; then sh_log "verify: green"
      else sh_log "verify: green after $i re-entry(ies)"; fi
      return 0
    fi

    if [ "$i" -ge "$max" ]; then break; fi
    i=$(( i + 1 ))
    sh_log "verify: red (exit $rc) — re-entry $i of $max"

    local vprompt; vprompt="$(mktemp)"
    {
      printf 'The verify gate failed. This ran against your changes:\n\n    %s\n\n' "$cmd"
      printf 'It exited %s. Last %s lines of combined output:\n\n' "$rc" "$SH_VERIFY_LOG_LINES"
      printf '```\n'; tail -n "$SH_VERIFY_LOG_LINES" "$log"; printf '```\n\n'
      # Without this the cheapest way to green the gate is to delete the check
      # or revert the work, and both would look like success from here.
      printf 'Fix the cause, so that command passes. Do not weaken, skip or delete a check to get a green result, and do not revert your work — the issue still has to be implemented.\n'
    } > "$vprompt"

    if ! claude_run verify_reentry "$vprompt" "${base}.reentry${i}" continue; then
      sh_log "verify: re-entry $i gave up — pushing what exists"
      rm -f "$vprompt"
      break
    fi
    rm -f "$vprompt"
  done

  # Always carries the command and its exit status, never just the output: a
  # command that fails QUIETLY (non-zero, nothing on stdout or stderr) would
  # otherwise leave an empty report, open-pr.sh would find nothing to quote, and
  # the pull request would look exactly like one whose gate had passed.
  SH_VERIFY_FAILED="$(
    printf '$ %s\nexited %s\n' "$cmd" "$rc"
    if [ -s "$log" ]; then
      printf '\n'; tail -n "$SH_VERIFY_LOG_LINES" "$log"
    else
      printf '\n(no output)\n'
    fi
  )"
  sh_log "verify: still red after $i re-entry(ies) — pushing anyway, CI is the backstop"
  return 0
}
