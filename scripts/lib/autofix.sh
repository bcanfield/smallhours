#!/usr/bin/env bash
# lib/autofix.sh — pure decisions for the CI auto-fix stage (T3', ADR 0009).
# Source this; do not execute.
#
# The stage's hard question is what an EMPTY working tree means. It used to
# mean "the agent could not fix it" — right for a code failure, wrong for every
# failure whose repair lives OUTSIDE the tree. A pull request title is the
# observed case (smallhours#30: correct code, green code checks, one red
# commit-format check; the agent retitled the PR, the check went green, and the
# toolkit handed the PR to a human as a failure anyway).
#
# The answer is read off the pull request, never off the agent's account of
# what it did: a claim the toolkit cannot check is not evidence, and a check
# run is. Every function here is pure — args/stdin in, stdout out, no gh, no
# network — so the decision is fixture-testable in tests/test-autofix.sh, and
# auto-fix.sh keeps every API call.
#
# stdin convention matches lib/sweep.sh's sweep_checks_green: pipe in the PR's
# statusCheckRollup array, e.g.
#   jq -c '.statusCheckRollup // []' <<< "$view" | autofix_checks_digest

[ -n "${_SMALLHOURS_AUTOFIX_SH:-}" ] && return 0
_SMALLHOURS_AUTOFIX_SH=1

# A one-line fingerprint of a PR's checks. Two digests differ iff a check
# appeared, disappeared, changed status or conclusion, or was RE-RUN — the
# timestamps are what make a re-run of an otherwise identical-looking job
# visible, and a re-run is one of the out-of-tree repairs this exists to see.
# Tolerates both shapes GitHub returns: check runs (.name/.status/.conclusion)
# and legacy commit statuses (.context/.state).
autofix_checks_digest() {
  jq -rs '
    (add // [])
    | map([ (.name // .context // ""), (.status // ""),
            (.conclusion // .state // ""),
            (.startedAt // .createdAt // ""), (.completedAt // "") ]
          | join("|"))
    | sort | join(";")' 2>/dev/null || true
}

# How many checks are still queued or running. Same status vocabulary as
# sweep_checks_green, for the same reason: one place decides what "in flight"
# means. A non-zero count is the toolkit's evidence that a `workflow_run`
# completed event is still coming, so this stage need not decide anything.
autofix_checks_pending() {
  jq -rs '
    [ (add // [])[] | (.status // "") | ascii_upcase
      | select(. == "QUEUED" or . == "IN_PROGRESS" or . == "PENDING") ] | length' \
    2>/dev/null || echo 0
}

# Has the PR's CI moved since the pre-run snapshot?
#   a check is in flight  -> an event is still coming
#   the digest changed    -> an event already fired
# Either way the PR's next state is the CI path's to decide, not this stage's.
#
# Deliberately does NOT require the movement to be the agent's doing: an
# unrelated check completing mid-run also means the event path is live, and
# treating that as "the agent did nothing" is the very over-claim #30 is about.
autofix_ci_moved() { # before-digest after-digest pending-count
  local pending="${3:-0}"
  case "$pending" in ''|*[!0-9]*) pending=0 ;; esac
  if [ "$pending" -gt 0 ] || [ "$1" != "$2" ]; then echo true; else echo false; fi
}

# What an empty working tree means, given what the pull request shows.
#
#   ci moved                    -> out-of-tree  a repair happened that is not a
#                                  commit; hand the PR back to the CI path.
#   title changed, CI still     -> stranded     the title is now right and
#                                  nothing will ever re-check it — the
#                                  consumer's CI does not run on
#                                  `pull_request: edited`. A real hand-off, but
#                                  for a nameable reason a human can act on.
#   nothing moved at all        -> no-changes   the original give-up, unchanged.
#
# `stranded` is the caller's cue to WAIT and ask again: a run that a retitle
# triggered takes a moment to appear, so this verdict is only final once the
# caller's window has closed.
autofix_clean_tree_outcome() { # title-changed(true|false) ci-moved(true|false)
  if [ "$2" = "true" ]; then
    echo out-of-tree
  elif [ "$1" = "true" ]; then
    echo stranded
  else
    echo no-changes
  fi
}
