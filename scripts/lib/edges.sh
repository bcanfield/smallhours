#!/usr/bin/env bash
# lib/edges.sh — blocking-edge logic for the edge-aware dispatcher (ADR 0006,
# tickets 06-2 / 06-3). Source this; do not execute.
#
# Native GitHub issue dependencies are the SINGLE canonical edge store; the
# promotion decision reads only them. A deterministic reconcile step parses any
# `## Blocked by` body section and upserts missing native relations from it,
# every tick. Parse/upsert failure is loud (one-time comment) and FAILS CLOSED
# (the issue stays blocked) — never a silent scheduling decision.
#
# The graph decisions (ref parsing, promotable computation, cycle detection)
# are pure text/JSON functions with no gh calls, exercised against fixtures in
# tests/. Only the reconcile/comment helpers touch the API.
#
# Depends on lib/common.sh (repo/log/comments).

[ -n "${_SMALLHOURS_EDGES_SH:-}" ] && return 0
_SMALLHOURS_EDGES_SH=1

_sh_edges_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$_sh_edges_dir/common.sh"

# ── Pure: parse a `## Blocked by` body section ───────────────────────────────
# edges_blocked_by_refs <owner/repo>   (issue body on stdin)
# One line per list item in the section: "ok:<number>" for a resolvable
# same-repo ref (#N or a full issue URL of this repo), "bad:<token>" for
# anything else (typo, cross-repo — unsupported in v1). Non-list lines in the
# section are ignored; no section means no output.
edges_blocked_by_refs() { # owner/repo
  local repo="$1" line item tok n
  awk '
    /^##[[:space:]]/ { insec = ($0 ~ /^##[[:space:]]+[Bb]locked[[:space:]]+[Bb]y[[:space:]]*$/); next }
    insec { print }
  ' | while IFS= read -r line; do
    case "$line" in
      '- '*|'* '*) item="${line#??}" ;;
      *) continue ;;
    esac
    tok="${item%% *}"
    case "$tok" in
      '#'*)
        n="${tok#\#}"
        case "$n" in
          ''|*[!0-9]*) printf 'bad:%s\n' "$tok" ;;
          *)           printf 'ok:%s\n' "$n" ;;
        esac ;;
      http*://github.com/*/issues/*)
        if printf '%s' "$tok" | grep -Eq "github\.com/$repo/issues/[0-9]+"; then
          printf 'ok:%s\n' "$(printf '%s' "$tok" | sed -E 's#.*/issues/([0-9]+).*#\1#')"
        else
          printf 'bad:%s\n' "$tok"
        fi ;;
      *) printf 'bad:%s\n' "$tok" ;;
    esac
  done
}

# ── Pure: promotable computation ─────────────────────────────────────────────
# stdin: [{number, bad, blocked_by: [{number, state, state_reason}, …]}, …]
# stdout: promotable issue numbers, ascending (the FIFO order). Promotable =
# not flagged bad AND every blocker closed as completed (ADR 0006: cleared
# means completed, not merely closed). No edges ⇒ trivially promotable.
edges_promotable() {
  jq -r '[ .[]
    | select((.bad // false) | not)
    | select(all(.blocked_by[]?; .state == "closed" and .state_reason == "completed"))
    | .number ] | sort | .[]'
}

# ── Pure: why a queued issue is NOT promotable ───────────────────────────────
# Same stdin as edges_promotable. One line per held issue, naming what holds
# it: "#295 held: blocked by #292 (open)". The inverse of edges_promotable —
# every queued issue appears in exactly one of the two.
#
# ADR 0006 rules out an issue-side signal (no marker label, no summary
# comment); this is the run-log side, where "promotable: <empty>" alone left no
# way to tell a blocked queue from a broken loop.
edges_held() {
  jq -r '.[]
    | select(((.bad // false)) or (any(.blocked_by[]?;
        .state != "closed" or .state_reason != "completed")))
    | "#\(.number) held: " + (
        if (.bad // false)
        then "unresolved `## Blocked by` reference — see the comment on the issue"
        else "blocked by " + ([ .blocked_by[]
               | select(.state != "closed" or .state_reason != "completed")
               | "#\(.number) (\(if .state == "closed"
                                 then "closed \(.state_reason // "?")"
                                 else .state end))" ] | join(", "))
        end)'
}

# ── Pure: plan-change detection (06-3) ───────────────────────────────────────
# Same stdin as edges_promotable. Prints "dependent<TAB>#blocker blocker-title"
# for every queued issue with a blocker closed as NOT_PLANNED — a plan change:
# re-planning is human judgment (ADR 0006).
edges_plan_changed() {
  jq -r '.[]
    | select((.bad // false) | not) as $i
    | $i.blocked_by[]?
    | select(.state == "closed" and .state_reason == "not_planned")
    | "\($i.number)\t#\(.number) \(.title // "")"'
}

# ── Pure: cycle detection (06-3) ─────────────────────────────────────────────
# stdin: adjacency object {"<issue>": ["<blocker>", …], …} over open queued
# issues (string keys/values). stdout: every member of a cycle, one number per
# line. A node is in a cycle iff it can reach itself (DFS closure; the graph
# is tiny, so a bounded fixpoint is fine).
edges_cycle_members() {
  jq -r '
    def succs($g; $xs): ([ $xs[] as $x | ($g[$x] // [])[] ] | unique);
    . as $g
    | [ keys[] | . as $k
        | select(
            reduce range(0; ($g | length) + 1) as $i
              (succs($g; [$k]); (. + succs($g; .)) | unique)
            | index($k) != null
          ) ]
    | sort_by(tonumber) | .[]'
}

# ── API: one-time comment (idempotent loudness) ──────────────────────────────
# Comments only if no existing comment carries the marker. Markers are HTML
# comments, invisible in the UI but greppable forever.
edges_comment_once() { # issue-number marker body
  local issue="$1" marker="$2" body="$3" repo
  repo="$(sh_repo)"
  if gh api "repos/$repo/issues/$issue/comments?per_page=100" --paginate \
       --jq '.[].body' 2>/dev/null | grep -Fq "$marker"; then
    return 0
  fi
  sh_comment_issue "$issue" "$body

<!-- $marker -->"
}

# ── API: reconcile one issue's body section into native relations ────────────
# edges_reconcile_issue <issue-number> <body-file>
# Upserts a native blocked-by relation for every resolvable body ref that is
# not already recorded. Prints "bad" (and comments, once) when any ref is
# unresolvable or an upsert fails — the caller must then treat the issue as
# blocked this tick (fail closed).
edges_reconcile_issue() { # issue-number body-file
  local issue="$1" bodyf="$2" repo refs existing bad=0 r n bid
  repo="$(sh_repo)"

  refs="$(edges_blocked_by_refs "$repo" < "$bodyf")"
  [ -n "$refs" ] || return 0

  existing="$(gh api "repos/$repo/issues/$issue/dependencies/blocked_by?per_page=100" \
                --jq '.[].number' 2>/dev/null || true)"

  while IFS= read -r r; do
    case "$r" in
      ok:*)
        n="${r#ok:}"
        if printf '%s\n' "$existing" | grep -Fxq "$n"; then
          continue  # body text wins over deletion — but this edge is present
        fi
        # Upsert needs the blocker's database id; a 404 here IS the
        # deleted/typo'd-issue case — unresolvable, fail closed.
        if ! bid="$(gh api "repos/$repo/issues/$n" --jq '.id' 2>/dev/null)"; then
          edges_comment_once "$issue" "smallhours:badref:$issue:$n" \
            "⚠️ This issue's \`## Blocked by\` section references \`#$n\`, which does not resolve to an issue in this repository. smallhours is keeping this issue **blocked** until the reference is fixed (edit the body) or resolves."
          bad=1; continue
        fi
        if gh api -X POST "repos/$repo/issues/$issue/dependencies/blocked_by" \
             -F "issue_id=$bid" >/dev/null 2>&1; then
          sh_log "edges: recorded #$issue blocked-by #$n"
        else
          edges_comment_once "$issue" "smallhours:edge-upsert-failed:$issue:$n" \
            "⚠️ smallhours could not record the dependency on #$n as a native issue relation (is the Fixer App missing issues WRITE permission? \`doctor\` checks this). Keeping this issue **blocked** until the edge can be recorded."
          sh_log "edges: UPSERT FAILED #$issue blocked-by #$n — failing closed"
          bad=1
        fi
        ;;
      bad:*)
        n="${r#bad:}"
        edges_comment_once "$issue" "smallhours:badref:$issue:$n" \
          "⚠️ This issue's \`## Blocked by\` section contains \`$n\`, which smallhours cannot resolve to an issue in this repository (cross-repo dependencies are unsupported). Keeping this issue **blocked** until the reference is fixed (edit the body)."
        bad=1
        ;;
    esac
  done <<< "$refs"

  [ "$bad" -eq 0 ] || printf 'bad\n'
  return 0
}
