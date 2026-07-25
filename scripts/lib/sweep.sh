#!/usr/bin/env bash
# lib/sweep.sh — decision helpers for the M7 sweep (T5/T6, watchdog, label
# reconciliation) and the shared green-gated T2 re-evaluation. Source this;
# do not execute.
#
# The decisions (merge-state routing, staleness, reconciliation target) are
# pure functions with no gh calls, exercised against fixtures in tests/. Only
# sweep_reeval_pr touches the API.
#
# Depends on lib/common.sh (repo/log) + lib/config.sh (ci_workflow).

[ -n "${_SMALLHOURS_SWEEP_SH:-}" ] && return 0
_SMALLHOURS_SWEEP_SH=1

_sh_sweep_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$_sh_sweep_dir/common.sh"
# shellcheck source=./config.sh
. "$_sh_sweep_dir/config.sh"

# ── Pure: route a mergeStateStatus to a sweep action ─────────────────────────
# DIRTY   -> conflict      (T6: draft + resolve-conflict stage)
# BEHIND  -> update-branch (T5: deterministic, no Claude)
# UNKNOWN -> skip          (DESIGN: do nothing; the next sweep retries)
# else    -> reeval        (CLEAN/BLOCKED/UNSTABLE/HAS_HOOKS: green-gated T2
#                           re-evaluation — state-manager already knows how to
#                           treat every one of these, sweep only re-runs it)
sweep_merge_action() { # mergeStateStatus
  case "$1" in
    DIRTY)   echo conflict ;;
    BEHIND)  echo update-branch ;;
    UNKNOWN) echo skip ;;
    *)       echo reeval ;;
  esac
}

# ── Pure: watchdog staleness ─────────────────────────────────────────────────
# Prints "true" when labeled-at is more than threshold-minutes before now.
# ISO-8601 parsing via jq (portable — GNU/BSD `date -d` flags differ).
sweep_is_stale() { # labeled-at-iso8601 now-epoch threshold-minutes
  jq -rn --arg t "$1" --argjson now "$2" --argjson m "$3" \
    '(($t | fromdateiso8601) as $at | ($now - $at) > ($m * 60))'
}

# ── Pure: reconciliation target for an issue carrying >1 state label ─────────
# The PR is the reality the labels must match (DESIGN: "state contradicts PR
# reality -> sweep reconciles"):
#   open agent PR, ready -> in-review      (review is the only pending act)
#   open agent PR, draft -> agent-working  (the coarse working span)
#   no PR, still queued  -> ready-for-agent (the drift was an extra label)
#   no PR, not queued    -> ready-for-human (nothing automated is in flight)
sweep_reconcile_target() { # pr-state(none|draft|ready) queued(true|false)
  case "$1" in
    ready) echo in-review ;;
    draft) echo agent-working ;;
    none)  [ "$2" = "true" ] && echo ready-for-agent || echo ready-for-human ;;
    *)     return 1 ;;
  esac
}

# ── Pure: next implement attempt from the remote branch list ─────────────────
# Branch names on stdin (one per line, no refs/heads/ prefix). Attempt 1 is
# agent/issue-N, retries are agent/issue-N-rK; the next attempt is one past the
# highest already minted, so a retry never force-pushes seen history (DESIGN).
sweep_next_attempt() { # issue-number
  local n="$1" max=0 b k
  while IFS= read -r b; do
    case "$b" in
      "agent/issue-$n")     k=1 ;;
      "agent/issue-$n-r"*)  k="${b##*-r}"
                            case "$k" in ''|*[!0-9]*) continue ;; esac ;;
      *)                    continue ;;
    esac
    [ "$k" -gt "$max" ] && max="$k"
  done
  printf '%s\n' "$((max + 1))"
}

# ── API: green-gated T2 re-evaluation for one agent PR ───────────────────────
# Re-runs state-manager's success path when the consumer CI's latest completed
# run on the PR head is green. Red (or no completed run) is left strictly
# alone: the workflow_run event already routed it, and re-feeding a failure
# here would burn auto-fix attempts without running auto-fix.
sweep_reeval_pr() { # pr-number
  local pr="$1" repo head wf concl
  repo="$(sh_repo)"
  head="$(gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName)"
  wf="$(config_ci_workflow)"
  concl="$(gh run list --repo "$repo" --workflow "$wf" --branch "$head" \
             --status completed --limit 1 --json conclusion \
             --jq '.[0].conclusion // empty' 2>/dev/null || true)"
  if [ "$concl" = "success" ]; then
    sh_log "reeval: PR #$pr — latest '$wf' on $head is green, re-running the T2 evaluation"
    "$_sh_sweep_dir/../state-manager.sh" "$pr" success >/dev/null
  else
    sh_log "reeval: PR #$pr — latest '$wf' on $head is '${concl:-none}', leaving it to the CI-event path"
  fi
}
