#!/usr/bin/env bash
# dispatch.sh — the bounded-queue, EDGE-AWARE dispatcher (ADR 0005 + 0006).
#
#   dispatch.sh
#
# `ready-for-agent` is an unbounded QUEUE of validated issues. Every tick this
# reconciler re-evaluates the full picture:
#
#   1. RECONCILE  — parse each queued issue's `## Blocked by` body section and
#                   upsert missing native issue-dependency relations (the
#                   single canonical edge store). Unresolvable refs and failed
#                   upserts comment once and FAIL CLOSED (issue stays blocked).
#   2. EJECT      — a blocker closed NOT_PLANNED is a plan change: dependents
#                   move to ready-for-human, once, with the dead blocker named.
#                   Cycles can never self-heal: every member is ejected too.
#   3. PROMOTE    — promotable = ready-for-agent AND every blocking edge
#                   cleared (blocker closed COMPLETED). FIFO among promotable
#                   issues only, up to `max_concurrent` in agent-working.
#
# No edges ⇒ no blockers ⇒ ADR 0005 behavior exactly. IDEMPOTENT: safe to run
# any number of times / from any trigger (schedule tick + post-authorize). One
# global concurrency group, so the slot count can't race.
#
# Env: GH_TOKEN (App token), GITHUB_REPOSITORY. Uses gh + jq (+ yq via config).
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/edges.sh"

main() {
  sh_require_auth
  local repo K; repo="$(sh_repo)"; K="$(config_max_concurrent)"

  # NOT local: the EXIT trap fires after main() returns, when a local would
  # already be out of scope — under set -u that failed every successful run.
  qdir="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-dispatch.XXXXXX")"
  trap 'rm -rf "${qdir:-}"' EXIT

  # The queue, oldest first (issue number ascending is a stable FIFO proxy).
  gh issue list --repo "$repo" --state open --label "$(label_for ready-for-agent)" \
    --limit 200 --json number,body --jq 'sort_by(.number)' > "$qdir/queued.json"
  local queued; queued="$(jq -r '.[].number' "$qdir/queued.json")"
  [ -n "$queued" ] || { sh_log "dispatch: queue empty"; exit 0; }

  # ── 1. Reconcile body edges into native relations (every tick, slots or not).
  local n
  for n in $queued; do
    jq -r --argjson n "$n" '.[] | select(.number == $n) | .body // ""' \
      "$qdir/queued.json" > "$qdir/body.$n"
    edges_reconcile_issue "$n" "$qdir/body.$n" > "$qdir/bad.$n"
  done

  # Per-issue edge state, from the native store ONLY (the promotion decision
  # never reads body text — reconcile above is what keeps the store truthful).
  local entries='[]' bad bb
  for n in $queued; do
    bad=false; [ -s "$qdir/bad.$n" ] && bad=true
    bb="$(gh api "repos/$repo/issues/$n/dependencies/blocked_by?per_page=100" \
            --jq '[.[] | {number, title, state, state_reason}]' 2>/dev/null)" || {
      # Can't read the edge store for this issue — fail closed, stay blocked.
      sh_log "dispatch: cannot read blocked_by for #$n — treating as blocked"
      bb='[]'; bad=true
    }
    entries="$(jq -n --argjson acc "$entries" --argjson n "$n" \
                     --argjson bad "$bad" --argjson bb "$bb" \
                     '$acc + [{number: $n, bad: $bad, blocked_by: $bb}]')"
  done

  # ── 2a. Plan-change ejection: a blocker closed NOT_PLANNED kills the plan.
  local ejected="" dep blocker
  while IFS=$'\t' read -r dep blocker; do
    [ -n "$dep" ] || continue
    sh_log "dispatch: plan change — #$dep's blocker $blocker closed not-planned, ejecting"
    state_set_issue "$dep" ready-for-human
    edges_comment_once "$dep" "smallhours:plan-change:$dep:${blocker%% *}" \
      "⛔ This issue is blocked by $blocker, which was closed as **not planned**. That is a plan change, and re-planning is human judgment — smallhours will not start work here. Marked \`$(label_for ready-for-human)\`; if this issue is still valid on its own, relabel it \`ready-for-agent\`."
    ejected="$ejected $dep"
  done < <(edges_plan_changed <<< "$entries")

  # ── 2b. Cycle ejection: no scheduling order is correct, and a cycle can
  # never self-heal — every member goes to a human.
  local adj cyc members_pretty
  adj="$(jq '[ .[] | { (.number | tostring):
                 [ .blocked_by[]? | select(.state == "open") | .number | tostring ] } ]
             | add // {}' <<< "$entries")"
  cyc="$(edges_cycle_members <<< "$adj")"
  if [ -n "$cyc" ]; then
    members_pretty="$(printf '#%s ' $cyc)"
    for n in $cyc; do
      sh_log "dispatch: dependency cycle — ejecting #$n (cycle: $members_pretty)"
      state_set_issue "$n" ready-for-human
      edges_comment_once "$n" "smallhours:cycle:$n" \
        "🔁 This issue is part of a dependency cycle (${members_pretty% }). No scheduling order can satisfy a cycle, so smallhours is handing every member to a human. Fix the \`## Blocked by\` sections / native relations, then relabel \`ready-for-agent\`."
      ejected="$ejected $n"
    done
  fi

  # ── 3. Promote: FIFO among promotable issues, into free slots.
  local working slots promoted=0 promotable
  working="$(gh issue list --repo "$repo" --state open --label "$(label_for agent-working)" \
              --limit 200 --json number --jq 'length')"
  slots=$(( K - working ))
  promotable="$(edges_promotable <<< "$entries")"
  # Drop anything ejected above (their labels changed after `entries` was built).
  for n in $ejected; do
    promotable="$(printf '%s\n' "$promotable" | grep -Fxv "$n" || true)"
  done
  sh_log "dispatch: max_concurrent=$K, agent-working=$working, free slots=$slots, promotable: $(printf '%s' "$promotable" | tr '\n' ' ')"

  if [ "$slots" -le 0 ]; then
    sh_log "dispatch: no free slots — nothing to promote"
    exit 0
  fi

  for n in $promotable; do
    [ -n "$n" ] || continue
    [ "$promoted" -lt "$slots" ] || break
    # Promote: ready-for-agent -> agent-working (fires the implement route).
    state_set_issue "$n" agent-working
    sh_log "dispatch: promoted #$n -> agent-working"
    promoted=$(( promoted + 1 ))
  done
  sh_log "dispatch: promoted $promoted issue(s) this run"
}

main "$@"
