#!/usr/bin/env bash
# test-sweep.sh — fixture-driven tests for the M7 sweep decisions (T5/T6,
# watchdog, label reconciliation, retry attempt derivation). Pure logic only
# (no gh, no network): the helpers in lib/sweep.sh.
# Run: tests/test-sweep.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$_dir/../scripts/lib/sweep.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-sweep.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

# Run a helper in a subshell so the config cache never leaks between cases.
run() { # helper args... [stdin via $RUN_STDIN]
  ( SMALLHOURS_CONFIG="$FIX/definitely-absent.yml"; unset GITHUB_WORKSPACE
    . "$SWEEP" 2>/dev/null || exit 90
    "$@" <<< "${RUN_STDIN:-}" )
}
RUN_STDIN=""

case_banner "merge-state routing (T5/T6/UNKNOWN/re-eval)"
[ "$(run sweep_merge_action DIRTY)"   = "conflict" ]      && ok "DIRTY -> conflict (T6)"        || bad "DIRTY misrouted"
[ "$(run sweep_merge_action BEHIND)"  = "update-branch" ] && ok "BEHIND -> update-branch (T5)"  || bad "BEHIND misrouted"
[ "$(run sweep_merge_action UNKNOWN)" = "skip" ]          && ok "UNKNOWN -> skip (DESIGN)"      || bad "UNKNOWN misrouted"
[ "$(run sweep_merge_action CLEAN)"   = "reeval" ]        && ok "CLEAN -> reeval"               || bad "CLEAN misrouted"
[ "$(run sweep_merge_action BLOCKED)" = "reeval" ]        && ok "BLOCKED -> reeval (stranding fix)" || bad "BLOCKED misrouted"
[ "$(run sweep_merge_action UNSTABLE)" = "reeval" ]       && ok "UNSTABLE -> reeval (state-manager keeps it draft)" || bad "UNSTABLE misrouted"

case_banner "T2 decision (green CI: CLEAN vs review-gated BLOCKED)"
[ "$(run sweep_t2_decision CLEAN '' true)" = "promote" ] \
  && ok "CLEAN -> promote (original T2)" || bad "CLEAN not promoted"
[ "$(run sweep_t2_decision UNKNOWN '' true)" = "skip" ] \
  && ok "UNKNOWN -> skip (DESIGN)" || bad "UNKNOWN not skipped"
[ "$(run sweep_t2_decision BLOCKED REVIEW_REQUIRED true)" = "promote" ] \
  && ok "BLOCKED by the required review alone -> promote" || bad "review-gated PR not promoted"
[ "$(run sweep_t2_decision BLOCKED REVIEW_REQUIRED false)" = "hold" ] \
  && ok "review pending but a check is red/running -> hold" || bad "promoted over a red check"
[ "$(run sweep_t2_decision BLOCKED CHANGES_REQUESTED true)" = "hold" ] \
  && ok "changes requested -> hold (T7 owns it)" || bad "changes-requested promoted"
[ "$(run sweep_t2_decision BLOCKED '' true)" = "hold" ] \
  && ok "BLOCKED for a non-review reason -> hold" || bad "opaque BLOCKED promoted"
[ "$(run sweep_t2_decision BEHIND '' true)" = "hold" ] \
  && ok "BEHIND -> hold (T5 updates the branch)" || bad "BEHIND promoted"
[ "$(run sweep_t2_decision DIRTY '' true)" = "hold" ] \
  && ok "DIRTY -> hold (T6 resolves)" || bad "DIRTY promoted"
[ "$(run sweep_t2_decision UNSTABLE '' true)" = "hold" ] \
  && ok "UNSTABLE -> hold (DESIGN: red is never ready)" || bad "UNSTABLE promoted"

case_banner "check rollup verdict"
RUN_STDIN='[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"SKIPPED"},{"status":"COMPLETED","conclusion":"NEUTRAL"}]'
[ "$(run sweep_checks_green)" = "true" ]  && ok "success/skipped/neutral -> green"      || bad "benign conclusions read as red"
RUN_STDIN='[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"FAILURE"}]'
[ "$(run sweep_checks_green)" = "false" ] && ok "a failing check -> not green"          || bad "failure missed"
RUN_STDIN='[{"status":"IN_PROGRESS","conclusion":null}]'
[ "$(run sweep_checks_green)" = "false" ] && ok "still-running check -> not green"      || bad "in-progress read as green"
RUN_STDIN='[{"status":"QUEUED","conclusion":null}]'
[ "$(run sweep_checks_green)" = "false" ] && ok "queued check -> not green"             || bad "queued read as green"
RUN_STDIN='[{"state":"SUCCESS"}]'
[ "$(run sweep_checks_green)" = "true" ]  && ok "legacy status SUCCESS -> green"        || bad "legacy success read as red"
RUN_STDIN='[{"state":"PENDING"}]'
[ "$(run sweep_checks_green)" = "false" ] && ok "legacy status PENDING -> not green"    || bad "legacy pending read as green"
RUN_STDIN='[{"state":"ERROR"}]'
[ "$(run sweep_checks_green)" = "false" ] && ok "legacy status ERROR -> not green"      || bad "legacy error read as green"
RUN_STDIN='[]'
[ "$(run sweep_checks_green)" = "true" ]  && ok "no checks reported -> green"           || bad "empty rollup read as red"
RUN_STDIN=""

case_banner "watchdog staleness (ISO-8601 vs threshold)"
# now = 2026-07-25T12:00:00Z as epoch
now=1784980800
[ "$(run sweep_is_stale '2026-07-25T10:00:00Z' "$now" 60)" = "true" ] \
  && ok "2h old at 60m threshold -> stale" || bad "2h old not stale"
[ "$(run sweep_is_stale '2026-07-25T11:30:00Z' "$now" 60)" = "false" ] \
  && ok "30m old at 60m threshold -> fresh" || bad "30m old read as stale"
[ "$(run sweep_is_stale '2026-07-25T11:00:00Z' "$now" 60)" = "false" ] \
  && ok "exactly 60m is NOT stale (strictly greater)" || bad "boundary counted as stale"
[ "$(run sweep_is_stale '2026-07-25T11:59:00Z' "$now" 0)" = "true" ] \
  && ok "threshold 0 (test override) makes any age stale" || bad "threshold 0 broken"

case_banner "reconciliation target follows PR reality"
[ "$(run sweep_reconcile_target ready false)" = "in-review" ] \
  && ok "ready PR -> in-review" || bad "ready PR misreconciled"
[ "$(run sweep_reconcile_target draft false)" = "agent-working" ] \
  && ok "draft PR -> agent-working" || bad "draft PR misreconciled"
[ "$(run sweep_reconcile_target none true)" = "ready-for-agent" ] \
  && ok "no PR + still queued -> ready-for-agent" || bad "queued misreconciled"
[ "$(run sweep_reconcile_target none false)" = "ready-for-human" ] \
  && ok "no PR + not queued -> ready-for-human" || bad "unqueued misreconciled"

case_banner "next attempt from surviving remote branches"
RUN_STDIN=""
[ "$(run sweep_next_attempt 7)" = "1" ] \
  && ok "no branches -> attempt 1" || bad "empty list not attempt 1"
RUN_STDIN="agent/issue-7"
[ "$(run sweep_next_attempt 7)" = "2" ] \
  && ok "plain branch survives -> attempt 2" || bad "plain branch not bumped"
RUN_STDIN=$'agent/issue-7\nagent/issue-7-r2\nagent/issue-7-r3'
[ "$(run sweep_next_attempt 7)" = "4" ] \
  && ok "r3 survives -> attempt 4" || bad "retry branch not bumped"
RUN_STDIN=$'agent/issue-72\nagent/issue-7-rX\nother/branch'
[ "$(run sweep_next_attempt 7)" = "1" ] \
  && ok "issue-72 / malformed -rX / unrelated never count for issue 7" || bad "near-miss branch counted"
RUN_STDIN=$'agent/issue-7-r10\nagent/issue-7-r9'
[ "$(run sweep_next_attempt 7)" = "11" ] \
  && ok "numeric (not lexical) comparison" || bad "r10 lost to r9 — lexical compare"
RUN_STDIN=""

echo
echo "test-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
