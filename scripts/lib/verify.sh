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
# An interactive login shell brackets the command with chatter of its own: it
# announces the missing tty before running anything, and prints `logout` on the
# way out. Neither is the consumer's output and both would otherwise be quoted
# on the pull request as if they were.
#
# Position is what makes this safe: only LEADING job-control lines and a
# trailing `logout` are dropped, so the same strings appearing in the middle —
# where they could only have come from the command — survive. Getting this wrong
# in the lenient direction would also mask a silent failure: a command that exits
# non-zero printing nothing must leave an EMPTY log, or the report says "here is
# the output" and shows bash talking to itself.
_verify_strip_shell_noise() { # log
  local log="$1" tmp="${1}.stripped"
  awk '
    !seen && /^bash: (cannot set terminal process group|no job control in this shell)/ { next }
    { seen = 1
      if (held) print prev
      prev = $0; held = 1 }
    END { if (held && prev != "logout") print prev }
  ' "$log" > "$tmp" && mv "$tmp" "$log"
}

# The executable bash reported as missing, or empty. Two passes rather than one
# expression: the prefix bash puts in front (`bash: line 3:`, `bash: eval:
# line 1:`) is not always there, and making it optional needs `\?`, which GNU sed
# has and BSD sed does not — this suite runs on both.
_verify_missing_command() { # log
  sed -n 's/: command not found$//p' "$1" | sed 's/.*: //' | tail -n 1
}

verify_gate() { # result_json
  local base="$1"
  local cmd; cmd="$(config_verify)"
  if [ -z "$cmd" ]; then return 0; fi

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
    # FULL SHELL INITIALISATION (ADR 0011). A bare `bash -c` sources no startup
    # file at all, so every toolchain the agent bootstrapped for itself was
    # invisible here — and since ADR 0008 chose "the agent installs its own
    # dependencies" over a setup phase, that is the common case, not an edge
    # one. This knows nothing about any language: exported vars (JAVA_HOME,
    # VIRTUAL_ENV, GOPATH) and shell functions (nvm, sdkman, pyenv, asdf) all
    # arrive by the same door.
    #
    # Three flags and an explicit source, because no single form is a superset:
    #   -i  installers append BELOW ~/.bashrc's `case $- in *i*) ;; *) return`
    #       guard, so a non-interactive shell reads none of it. `bash -lc`, the
    #       obvious one-word fix, resolves nothing for this reason.
    #   -l  picks up /etc/profile and the profile chain, where system-wide and
    #       some per-user toolchains land instead.
    #   . ~/.bashrc  because a LOGIN shell reads ~/.bash_profile OR ~/.bash_login
    #       OR ~/.profile and never ~/.bashrc directly. Ubuntu's stock ~/.profile
    #       sources it, but any installer that drops a ~/.bash_profile shadows
    #       that file and silently severs the chain. Re-sourcing when the profile
    #       already did is safe — rc files guard their own PATH edits.
    #
    # `-i` also drags in /etc/bash.bashrc, where Debian and Ubuntu define
    # `command_not_found_handle` — so a missing command prints the distro's
    # apt-suggestion text instead of bash's own `…: command not found`, and the
    # classification below silently stops recognising it. Unset it: a
    # package-suggestion nicety for humans at a prompt has no business in a CI
    # gate, where it costs an apt-database query and makes the one message this
    # gate has to parse depend on which distro the runner happens to be.
    #
    # The command travels in the environment and is eval'd rather than being
    # interpolated into the -c string: an interactive shell history-expands what
    # it parses, so a `!` anywhere in the consumer's command would otherwise be
    # mangled before it ever ran.
    env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      SH_VERIFY_CMD="$cmd" \
      bash -lic 'set +H
                 [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc" || true
                 unset -f command_not_found_handle 2>/dev/null || true
                 _c="$SH_VERIFY_CMD"; unset SH_VERIFY_CMD; eval "$_c"' \
      > "$log" 2>&1 || rc=$?
    _verify_strip_shell_noise "$log"
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
