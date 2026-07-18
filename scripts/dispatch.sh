#!/usr/bin/env bash
# dispatch.sh — the bounded-queue dispatcher (Phase 1 minimal sweep).
#
#   dispatch.sh
#
# `ready-for-agent` is an unbounded QUEUE of validated issues. This reconciler
# keeps at most `max_concurrent` issues in `agent-working` at once: it counts
# in-flight work and promotes the oldest queued issues to fill the free slots.
# Promotion sets `agent-working`, which (App-applied, so it re-triggers) fires
# the implement route via the label-chain.
#
# IDEMPOTENT: safe to run any number of times / from any trigger. It is invoked
# on the `schedule` tick (drains the queue as slots free) and right after a
# successful authorize (starts a just-queued issue promptly when there is room).
# The dispatcher job runs under one global concurrency group, so only one
# instance runs at a time and the slot count can't race.
#
# Env: GH_TOKEN (App token), GITHUB_REPOSITORY. Uses gh + jq only.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"

main() {
  sh_require_auth
  local repo K working slots
  repo="$(sh_repo)"
  K="$(config_max_concurrent)"

  # Slots in use = open issues currently being worked.
  working="$(gh issue list --repo "$repo" --state open --label agent-working \
              --limit 200 --json number --jq 'length')"
  slots=$(( K - working ))
  sh_log "dispatch: max_concurrent=$K, agent-working=$working, free slots=$slots"

  if [ "$slots" -le 0 ]; then
    sh_log "dispatch: no free slots — nothing to promote"
    exit 0
  fi

  # Oldest queued first (issue number ascending is a stable FIFO proxy).
  local queued promoted=0 n
  queued="$(gh issue list --repo "$repo" --state open --label ready-for-agent \
             --limit 200 --json number --jq 'sort_by(.number) | .[].number')"
  [ -n "$queued" ] || { sh_log "dispatch: queue empty"; exit 0; }

  for n in $queued; do
    [ "$promoted" -lt "$slots" ] || break
    # Promote: ready-for-agent -> agent-working (fires the implement route).
    state_set_issue "$n" agent-working
    sh_log "dispatch: promoted #$n -> agent-working"
    promoted=$(( promoted + 1 ))
  done
  sh_log "dispatch: promoted $promoted issue(s) this run"
}

main "$@"
