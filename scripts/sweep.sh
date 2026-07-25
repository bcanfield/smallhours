#!/usr/bin/env bash
# sweep.sh — the M7 scheduled reconciler. Runs every tick (schedule cron or a
# manual workflow_dispatch); every pass re-derives everything from GitHub state,
# so it is idempotent and late/missed ticks only delay, never corrupt.
#
#   sweep.sh
#
# Per open `agent` PR (same-repo head hard-checked, DESIGN):
#   DIRTY   -> T6: schedule the resolve-conflict stage — AT MOST ONE per tick
#              (risk register: the sweep is 1 Claude run max per cycle); the
#              rest wait for a later tick.
#   BEHIND  -> T5: update the branch from base (deterministic, no Claude).
#   UNKNOWN -> skip; the next sweep retries.
#   else    -> green-gated T2 re-evaluation (rescues green-but-never-promoted
#              PRs, e.g. after a required-approval unblocked a green revision).
#
# Watchdog: an `agent-working` issue with no open agent PR after
# SMALLHOURS_WATCHDOG_MINUTES (default 60 — DESIGN "~1h"; the implement job
# times out at 40m, so a live run can never trip this) -> ready-for-human.
#
# Label reconciliation: an open issue carrying more than one state label is
# healed toward its PR reality (lib/sweep.sh sweep_reconcile_target) + comment.
#
# stdout is a machine value: `conflict=<pr>` when the caller should run the
# resolve-conflict stage, nothing otherwise. All logging goes to stderr (fd-4
# isolation, same contract as implement.sh / state-manager.sh).
# Env: GH_TOKEN (App token), GITHUB_REPOSITORY.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"
. "$_dir/lib/sweep.sh"

WATCHDOG_MINUTES="${SMALLHOURS_WATCHDOG_MINUTES:-60}"

main() {
  sh_require_auth
  local repo; repo="$(sh_repo)"

  # stdout carries only the machine decision; everything else -> stderr.
  exec 4>&1 1>&2

  # One snapshot of the open agent PRs drives all three passes.
  local prs_json
  prs_json="$(gh pr list --repo "$repo" --state open --label "$(label_for agent)" \
                --limit 100 --json number,isDraft,mergeStateStatus,headRefName,isCrossRepository,labels)"

  local conflict_pr="" human_needed
  human_needed="$(label_for human-needed)"
  local n merge cross action

  # ── T5 / T6 / T2 re-eval over the agent PRs ────────────────────────────────
  while IFS=$'\t' read -r n merge cross; do
    [ -n "$n" ] || continue
    if [ "$cross" = "true" ]; then
      # Hard same-repo check (DESIGN) — never touch a fork-headed PR, even if
      # someone hand-applied the agent label.
      sh_log "sweep: PR #$n has a cross-repository head — ignoring"
      continue
    fi
    action="$(sweep_merge_action "$merge")"
    case "$action" in
      conflict)
        # A prior resolve attempt gave up and marked the PR human-needed:
        # retrying every tick would spend Claude forever on the same wall.
        # A human clearing the label (or pushing a fix) re-arms the stage.
        if jq -e --argjson n "$n" --arg l "$human_needed" \
             '.[] | select(.number == $n) | any(.labels[]?; .name == $l)' \
             <<< "$prs_json" >/dev/null; then
          sh_log "sweep: PR #$n is DIRTY but marked $human_needed — awaiting a human (remove the label to retry)"
        elif [ -z "$conflict_pr" ]; then
          conflict_pr="$n"
          sh_log "sweep: PR #$n is DIRTY — scheduling conflict resolution (T6)"
        else
          sh_log "sweep: PR #$n is DIRTY too — deferred (one conflict run per tick)"
        fi
        ;;
      update-branch)
        sh_log "sweep: PR #$n is BEHIND — updating branch from base (T5)"
        gh api -X PUT "repos/$repo/pulls/$n/update-branch" >/dev/null 2>&1 \
          || sh_log "sweep: update-branch failed on PR #$n — left for the next tick"
        ;;
      skip)
        sh_log "sweep: PR #$n mergeStateStatus UNKNOWN — skipping this tick"
        ;;
      reeval)
        sweep_reeval_pr "$n"
        ;;
    esac
  done < <(jq -r '.[] | [.number, .mergeStateStatus, .isCrossRepository] | @tsv' <<< "$prs_json")

  # ── Watchdog: agent-working + no open agent PR after ~1h -> dead runner ────
  local now i at stale
  now="$(date +%s)"
  while IFS= read -r i; do
    [ -n "$i" ] || continue
    if jq -e --arg re "^agent/issue-${i}(-r[0-9]+)?$" \
         '[.[] | select(.headRefName | test($re))] | length > 0' <<< "$prs_json" >/dev/null; then
      continue  # a live PR holds the slot legitimately
    fi
    at="$(gh api "repos/$repo/issues/$i/events?per_page=100" --paginate 2>/dev/null \
            | jq -rs --arg l "$(label_for agent-working)" \
                '[(add // [])[] | select(.event == "labeled" and .label.name == $l)]
                 | (last | .created_at) // empty')" || at=""
    if [ -z "$at" ]; then
      sh_log "sweep: watchdog cannot date agent-working on #$i — leaving it"
      continue
    fi
    stale="$(sweep_is_stale "$at" "$now" "$WATCHDOG_MINUTES")"
    if [ "$stale" = "true" ]; then
      sh_log "sweep: watchdog — #$i agent-working since $at with no open agent PR, reclaiming (dead runner)"
      state_set_issue "$i" ready-for-human
      sh_comment_issue "$i" \
        "⏰ This issue has been \`$(label_for agent-working)\` for over ${WATCHDOG_MINUTES} minutes with no open agent pull request — the run that owned it most likely died. smallhours reclaimed the slot and marked it \`$(label_for ready-for-human)\`. Relabel \`$(label_for ready-for-agent)\` to retry."
    fi
  done < <(gh issue list --repo "$repo" --state open \
             --label "$(label_for agent-working)" --limit 200 \
             --json number --jq '.[].number')

  # ── Label reconciliation: exactly-one-state-label invariant ────────────────
  local axis pr_state queued target seen
  axis="$(state_labels_resolved | jq -R . | jq -s .)"
  while IFS=$'\t' read -r i seen; do
    [ -n "$i" ] || continue
    if jq -e --arg re "^agent/issue-${i}(-r[0-9]+)?$" \
         '[.[] | select(.headRefName | test($re))] | length > 0' <<< "$prs_json" >/dev/null; then
      if jq -e --arg re "^agent/issue-${i}(-r[0-9]+)?$" \
           '[.[] | select(.headRefName | test($re))][0].isDraft' <<< "$prs_json" >/dev/null; then
        pr_state=draft
      else
        pr_state=ready
      fi
    else
      pr_state=none
    fi
    queued=false
    printf '%s\n' "$seen" | tr ',' '\n' | grep -Fxq "$(label_for ready-for-agent)" && queued=true
    target="$(sweep_reconcile_target "$pr_state" "$queued")"
    sh_log "sweep: #$i carries multiple state labels ($seen) — reconciling to $target"
    state_set_issue "$i" "$target"
    sh_comment_issue "$i" \
      "🧹 This issue carried more than one state label (${seen}) — that breaks the exactly-one-state invariant, usually after a by-hand label edit. smallhours reconciled it to \`$(label_for "$target")\` based on the state of its agent pull request."
  done < <(jq -r --argjson axis "$axis" \
             '.[] | . as $i
              | [.labels[].name | select(. as $x | $axis | index($x))] as $states
              | select(($states | length) >= 2)
              | [$i.number, ($states | join(","))] | @tsv' \
             <<< "$(gh issue list --repo "$repo" --state open --limit 200 --json number,labels)")

  # ── Machine output ─────────────────────────────────────────────────────────
  if [ -n "$conflict_pr" ]; then
    printf 'conflict=%s\n' "$conflict_pr" >&4
  fi
  sh_log "sweep: pass complete"
}

main "$@"
