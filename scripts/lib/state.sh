#!/usr/bin/env bash
# lib/state.sh — the single choke point for issue-state and PR-marker labels.
# Source this; do not execute.
#
# THE invariant (CONTEXT.md): every triaged issue carries EXACTLY ONE state
# label at all times; transitions REPLACE, never accumulate. Nothing outside
# this file may add/remove a state label — that is how the invariant is kept.
#
# Depends on lib/config.sh (label vocabulary) + lib/common.sh (repo/log).

[ -n "${_SMALLHOURS_STATE_SH:-}" ] && return 0
_SMALLHOURS_STATE_SH=1

_sh_state_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$_sh_state_dir/config.sh"
# shellcheck source=./common.sh
. "$_sh_state_dir/common.sh"

# Is $1 a recognised issue state label?
_sh_is_state_label() {
  local l
  for l in "${SMALLHOURS_STATE_LABELS[@]}"; do [ "$l" = "$1" ] && return 0; done
  return 1
}

# Current state label(s) on an issue — should be zero or one; more than one is
# drift that state_set_issue heals on its next call.
state_current() { # issue-number
  local repo; repo="$(sh_repo)"
  gh issue view "$1" --repo "$repo" --json labels \
    --jq '.labels[].name' | grep -Fxf <(printf '%s\n' "${SMALLHOURS_STATE_LABELS[@]}") || true
}

# Move an issue to exactly one state label. Adds the target first (so the issue
# is never momentarily label-less), then strips every OTHER state label present.
# Idempotent: re-setting the current state is a no-op that still heals drift.
state_set_issue() { # issue-number new-state
  local issue="$1" want="$2" repo
  repo="$(sh_repo)"
  _sh_is_state_label "$want" || sh_die "not a state label: '$want'"

  # Add the target label. --add-label is idempotent on GitHub's side.
  gh issue edit "$issue" --repo "$repo" --add-label "$want" >/dev/null

  # Remove any other state labels currently present.
  local cur remove=()
  while IFS= read -r cur; do
    [ -n "$cur" ] || continue
    [ "$cur" = "$want" ] && continue
    remove+=("$cur")
  done < <(state_current "$issue")

  if [ "${#remove[@]}" -gt 0 ]; then
    local args=() l
    for l in "${remove[@]}"; do args+=(--remove-label "$l"); done
    gh issue edit "$issue" --repo "$repo" "${args[@]}" >/dev/null
  fi
  sh_log "issue #$issue state -> $want"
}

# ── PR marker labels (not the state axis) ─────────────────────────────────────
state_pr_add_label() { # pr-number label...
  local pr="$1"; shift
  local repo args=() l; repo="$(sh_repo)"
  for l in "$@"; do args+=(--add-label "$l"); done
  gh pr edit "$pr" --repo "$repo" "${args[@]}" >/dev/null
}

state_pr_remove_label() { # pr-number label...
  local pr="$1"; shift
  local repo args=() l; repo="$(sh_repo)"
  for l in "$@"; do args+=(--remove-label "$l"); done
  # --remove-label errors if the label isn't present; tolerate that.
  gh pr edit "$pr" --repo "$repo" "${args[@]}" >/dev/null 2>&1 || true
}
