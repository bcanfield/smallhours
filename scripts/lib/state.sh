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

# Current state label(s) on an issue, as they appear on the repo (resolved
# strings, not canonical names) — should be zero or one; more than one is
# drift that state_set_issue heals on its next call.
state_current() { # issue-number
  local repo; repo="$(sh_repo)"
  gh issue view "$1" --repo "$repo" --json labels \
    --jq '.labels[].name' | grep -Fxf <(state_labels_resolved) || true
}

# Move an issue to exactly one state label. Takes the CANONICAL name and
# resolves it through the labels: mapping at this choke point — callers never
# see repo label strings. Adds the target first (so the issue is never
# momentarily label-less), then strips every OTHER state label present.
# Idempotent: re-setting the current state is a no-op that still heals drift.
state_set_issue() { # issue-number new-state(canonical)
  local issue="$1" canonical="$2" want repo
  repo="$(sh_repo)"
  _sh_is_state_label "$canonical" || sh_die "not a state label: '$canonical'"
  want="$(label_for "$canonical")" || sh_die "label mapping failed for '$canonical'"

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
  sh_log "issue #$issue state -> $canonical ($want)"
}

# ── Auto-fix attempt counter (T3'/T4) ─────────────────────────────────────────
# Attempt N of the CI auto-fix loop is the PR label `autofix-attempt-N`.
# System-internal: never a workflow trigger, never human-applied, and NOT part
# of the labels: mapping (docs/debt autofix-attempt-labels-unmappable) — so the
# label is created on demand rather than assumed by setup. At most one attempt
# label per PR; ANY green CI strips it (DESIGN: the cap counts *consecutive*
# failures only).

# Pure half, testable offline: read label names on stdin, print the highest
# attempt number present (0 when none).
state_autofix_attempt_from_labels() {
  local n
  n="$(sed -n 's/^autofix-attempt-\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -n 1)"
  printf '%s\n' "${n:-0}"
}

# Current attempt count on a PR.
state_autofix_attempt() { # pr-number
  gh pr view "$1" --repo "$(sh_repo)" --json labels --jq '.labels[].name' \
    | state_autofix_attempt_from_labels
}

# Move a PR to attempt N: add autofix-attempt-N, strip any other attempt label.
state_autofix_set_attempt() { # pr-number N
  local pr="$1" n="$2" repo cur; repo="$(sh_repo)"
  gh label create "autofix-attempt-$n" --repo "$repo" --color f9d0c4 \
    --description "PR: consecutive CI auto-fix attempt $n (system-managed)" \
    2>/dev/null || true
  gh pr edit "$pr" --repo "$repo" --add-label "autofix-attempt-$n" >/dev/null
  while IFS= read -r cur; do
    case "$cur" in
      "autofix-attempt-$n") : ;;
      autofix-attempt-*)
        gh pr edit "$pr" --repo "$repo" --remove-label "$cur" >/dev/null 2>&1 || true ;;
    esac
  done < <(gh pr view "$pr" --repo "$repo" --json labels --jq '.labels[].name')
  sh_log "PR #$pr auto-fix attempt -> $n"
}

# Strip every attempt label (any green CI resets the consecutive counter).
state_autofix_clear() { # pr-number
  local pr="$1" repo cur; repo="$(sh_repo)"
  while IFS= read -r cur; do
    case "$cur" in
      autofix-attempt-*)
        gh pr edit "$pr" --repo "$repo" --remove-label "$cur" >/dev/null 2>&1 || true
        sh_log "PR #$pr attempt label '$cur' stripped (green resets the counter)" ;;
    esac
  done < <(gh pr view "$pr" --repo "$repo" --json labels --jq '.labels[].name')
}

# ── PR marker labels (not the state axis) ─────────────────────────────────────
# Args are CANONICAL names, resolved here (same choke-point rule as above).
state_pr_add_label() { # pr-number label...
  local pr="$1"; shift
  local repo args=() l r; repo="$(sh_repo)"
  for l in "$@"; do
    r="$(label_for "$l")" || sh_die "label mapping failed for '$l'"
    args+=(--add-label "$r")
  done
  gh pr edit "$pr" --repo "$repo" "${args[@]}" >/dev/null
}

state_pr_remove_label() { # pr-number label...
  local pr="$1"; shift
  local repo args=() l r; repo="$(sh_repo)"
  for l in "$@"; do
    r="$(label_for "$l")" || sh_die "label mapping failed for '$l'"
    args+=(--remove-label "$r")
  done
  # --remove-label errors if the label isn't present; tolerate that.
  gh pr edit "$pr" --repo "$repo" "${args[@]}" >/dev/null 2>&1 || true
}
