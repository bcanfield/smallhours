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

# Set by verify_gate to the name of the executable that could not be resolved,
# when the gate NEVER STARTED. Distinct from SH_VERIFY_FAILED being non-empty:
# "your code is broken" and "your gate could not run" are different messages and
# only one of them is about the agent's work.
SH_VERIFY_UNRESOLVED=""

# verify_gate <result_json>
#   $1  the stage's result-JSON path; used only to derive sibling scratch paths
#       (the log, and one result file per re-entry).
# Always returns 0.
#
# Re-entry results go to their OWN files on purpose: report-usage.sh reads the
# stage's $RESULT_JSON, and overwriting it would replace the implement run's
# usage figures with a repair's.
# The tool directory (ADR 0014) goes on PATH here rather than in the environment
# of the shell, and is EXPORTED, so a consumer script that re-invokes its own
# package manager by name finds it too. Prepending from outside is not enough
# where a shell rebuilds PATH; doing it inside works either way.
_SH_VERIFY_SHELL_PREAMBLE='[ -n "${SMALLHOURS_TOOL_BIN:-}" ] && export PATH="$SMALLHOURS_TOOL_BIN:$PATH"
'

# The executable bash reported as missing, or empty. Two passes rather than one
# expression: the prefix bash puts in front (`bash: line 3:`, `bash: eval:
# line 1:`) is not always there, and making it optional needs `\?`, which GNU sed
# has and BSD sed does not — this suite runs on both.
_verify_missing_command() { # log
  sed -n 's/: command not found$//p' "$1" | sed 's/.*: //' | tail -n 1
}

# Why one name did not resolve, in the log only — the pull request gets a remedy,
# not a dump. Since ADR 0014 there is exactly one place an agent-installed tool
# can be, and verify_gate lists its contents on every run, so all that is left to
# say here is what the gate's own PATH was.
#
# Swallows its own failure: implement.sh runs `set -euo pipefail` and sources this
# file, so a probe exiting non-zero would abort the run at the point where the
# branch still has to be pushed and the PR still has to explain itself.
_verify_diagnose() { # missing
  local missing="$1" path
  path="$(env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
    bash -c "${_SH_VERIFY_SHELL_PREAMBLE}"'printf "%s\n" "$PATH"' 2>/dev/null | tail -n 1)" || true
  sh_log "verify: diagnose: PATH was ${path:-<empty>}"
  sh_log "verify: diagnose: a tool the agent installs has to land in \$SMALLHOURS_TOOL_BIN (ADR 0014); \
one reached any other way does not outlive the command that reached it."
}

verify_gate() { # result_json
  local base="$1"
  local cmd; cmd="$(config_verify)"
  if [ -z "$cmd" ]; then return 0; fi

  # What the agent installed for itself, EVERY run and not only on failure. It
  # is the only review surface this mechanism has: unlike an edit to the script
  # the gate invokes, these bytes never appear in a diff, and the gate runs them
  # outside the sandbox (ADR 0014). A shim that greens the gate is visible here
  # or nowhere.
  if [ -n "${SMALLHOURS_TOOL_BIN:-}" ] && [ -d "$SMALLHOURS_TOOL_BIN" ]; then
    local tools; tools="$(ls -1 "$SMALLHOURS_TOOL_BIN" 2>/dev/null | tr '\n' ' ')" || true
    if [ -n "$tools" ]; then sh_log "verify: tools the agent installed: $tools"
    else sh_log "verify: tools the agent installed: none"; fi
  fi

  local max log i=0 rc=0 first
  max="$(config_verify_reentries)"
  log="${base}.verify"
  SH_VERIFY_FAILED=""
  SH_VERIFY_UNRESOLVED=""
  # First word of the configured command, used only to tell "the gate never
  # started" from "something the gate ran was missing". A leading `VAR=x` or a
  # builtin like `cd` makes this not match the missing name, which costs a
  # re-entry we would have spent anyway — the conservative direction.
  read -r first _ <<< "$cmd"

  while :; do
    rc=0
    # Runs the consumer's own scripts — which the agent just had the chance to
    # edit — and unlike the agent's Bash calls this is NOT inside the sandbox.
    # The tokens are the one thing worth withholding: the `.git/config`
    # credentials are load-bearing for the push and stay, but nothing a verify
    # command legitimately does needs GH_TOKEN.
    #
    # A PLAIN SHELL (ADR 0014). ADR 0011 ran this login+interactive and sourced
    # ~/.bashrc so a toolchain the agent installed would be visible; reading the
    # sandbox documentation later showed that case cannot occur — the agent
    # cannot write ~/.bashrc, or any directory on PATH, so no installer of its
    # can leave anything in a startup file. What it CAN write is the tool
    # directory, which the preamble puts on PATH and exports, so a consumer
    # script that re-invokes its own package manager by name finds it too.
    #
    # The command still travels in the environment and is eval'd rather than
    # interpolated into the -c string: it keeps the consumer's quoting intact
    # whatever it contains.
    env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      SH_VERIFY_CMD="$cmd" \
      bash -c "${_SH_VERIFY_SHELL_PREAMBLE}"'_c="$SH_VERIFY_CMD"; unset SH_VERIFY_CMD; eval "$_c"' \
      > "$log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$i" -eq 0 ]; then sh_log "verify: green"
      else sh_log "verify: green after $i re-entry(ies)"; fi
      return 0
    fi

    # The gate never started: the command's own executable does not resolve, so
    # nothing about the agent's work has been checked. Re-entry cannot succeed —
    # the agent has no way to change the shell the gate runs in — and one costs a
    # whole Claude stage. mediamtx-connect#300 spent 31 turns and $2.22 here
    # rewriting correct code before hitting max_turns (#29).
    if [ "$rc" -eq 127 ]; then
      local missing; missing="$(_verify_missing_command "$log")"
      if [ -n "$missing" ] && [ "$missing" = "$first" ]; then
        SH_VERIFY_UNRESOLVED="$missing"
        sh_log "verify: could not run — \`$missing\` is not on PATH; no re-entry, nothing was checked"
        _verify_diagnose "$missing"
        break
      fi
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
  if [ -n "$SH_VERIFY_UNRESOLVED" ]; then
    sh_log "verify: pushing unchecked — the gate could not run, CI is the only backstop"
  else
    sh_log "verify: still red after $i re-entry(ies) — pushing anyway, CI is the backstop"
  fi
  return 0
}
