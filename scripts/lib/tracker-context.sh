#!/usr/bin/env bash
# lib/tracker-context.sh — deterministic tracker-context assembly (ADR 0006 /
# ticket 06-4). Source this; do not execute.
#
# Enriches the implement prompt with what the tracker knows: the parent spec
# inlined VERBATIM (never summarized — summarizing is a model act, this step is
# deterministic), plus a one-line pointer per cleared blocker so the agent
# knows what already landed on the default branch before its checkout.
#
# Ticket convention (CONTEXT.md "Parent spec"): a body line
#   Spec: <#issue | repo-relative path | issue URL>
# names the spec the ticket was cut from. First such line wins. No line, no
# section — a repo without Pocock artifacts produces today's context unchanged.
#
# Everything here is ENRICHMENT: any lookup failure degrades to an absent
# section, never a failed implement run.

[ -n "${_SMALLHOURS_TRACKER_CONTEXT_SH:-}" ] && return 0
_SMALLHOURS_TRACKER_CONTEXT_SH=1

_sh_tc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$_sh_tc_dir/common.sh"

# Parse the spec reference out of an issue body (stdin). Pure text -> text:
# prints "issue:<n>" or "file:<path>", or nothing when the body has no Spec:
# line. Markdown links and full issue URLs are unwrapped.
tc_spec_ref() {
  local ref
  ref="$(sed -n -E 's/^[Ss]pec:[[:space:]]*(.+)[[:space:]]*$/\1/p' | head -1)"
  [ -n "$ref" ] || return 0
  # [text](target) -> target
  case "$ref" in
    *']('*')'*) ref="$(printf '%s' "$ref" | sed -E 's/.*\]\(([^)]+)\).*/\1/')" ;;
  esac
  ref="${ref%% *}"
  case "$ref" in
    '#'*[!0-9]*) return 0 ;;                       # "#12abc" — not a ref
    '#'[0-9]*)   printf 'issue:%s\n' "${ref#\#}" ;;
    *github.com/*/issues/[0-9]*)
      printf 'issue:%s\n' "$(printf '%s' "$ref" | sed -E 's#.*/issues/([0-9]+).*#\1#')" ;;
    http*://*)   return 0 ;;                       # foreign URL — not inlinable
    *)           printf 'file:%s\n' "$ref" ;;
  esac
}

# One line per CLEARED blocker (closed completed — ADR 0006 unblock semantics).
# Reads the native dependency relations only; a repo/token without the
# dependencies API degrades to no output.
tc_cleared_blockers() { # issue-number
  local repo; repo="$(sh_repo)"
  gh api "repos/$repo/issues/$1/dependencies/blocked_by" --paginate \
    --jq '.[] | select(.state == "closed" and .state_reason == "completed")
              | "- #\(.number) \(.title) (closed as completed)"' \
    2>/dev/null || true
}

# Append the tracker-context sections for an issue to stdout. Args: the issue
# number and a file holding its RAW body (for spec-line parsing).
tracker_context() { # issue-number body-file
  local issue="$1" bodyf="$2" repo ref n p spec blockers
  repo="$(sh_repo)"

  ref="$(tc_spec_ref < "$bodyf")"
  case "$ref" in
    issue:*)
      n="${ref#issue:}"
      spec="$(gh issue view "$n" --repo "$repo" --json body --jq '.body // empty' 2>/dev/null || true)"
      if [ -n "$spec" ]; then
        printf '\n## Parent spec (issue #%s, inlined verbatim)\n\n%s\n' "$n" "$spec"
      else
        sh_log "tracker-context: spec ref #$n unreadable — section omitted"
      fi
      ;;
    file:*)
      p="${ref#file:}"
      if [ -f "$p" ]; then
        printf '\n## Parent spec (%s, inlined verbatim)\n\n' "$p"
        cat "$p"
      else
        sh_log "tracker-context: spec file '$p' not in checkout — section omitted"
      fi
      ;;
  esac

  blockers="$(tc_cleared_blockers "$issue")"
  if [ -n "$blockers" ]; then
    printf '\n## Blockers already landed\n\nThese prerequisite issues are done; their changes are on the default branch you checked out:\n\n%s\n' "$blockers"
  fi
  return 0
}
