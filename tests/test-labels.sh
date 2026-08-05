#!/usr/bin/env bash
# test-labels.sh — fixture-driven tests for the label resolver (06-1, ADR 0006).
# Pure config logic only (jq + yq, no gh, no network). Run: tests/test-labels.sh
#
# Each case sources lib/config.sh in a SUBSHELL with SMALLHOURS_CONFIG pointed
# at a fixture, so the config cache never leaks between cases.
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$_dir/../scripts/lib/config.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-labels.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

# run_lib <config-path-or-empty> <shell-snippet> — prints snippet stdout,
# returns its exit code.
run_lib() {
  local cfg="$1" snippet="$2"
  ( SMALLHOURS_CONFIG="${cfg:-$FIX/definitely-absent.yml}"; unset GITHUB_WORKSPACE
    . "$LIB" 2>/dev/null || exit 90
    eval "$snippet" )
}

case_banner "no config file -> canonical defaults"
[ "$(run_lib "" 'label_for in-review')" = "in-review" ] \
  && ok "label_for falls back to canonical" || bad "expected canonical fallback"
[ "$(run_lib "" 'state_labels_resolved | wc -l | tr -d " "')" = "7" ] \
  && ok "state axis has 7 labels" || bad "state axis wrong size"

case_banner "mapping resolves; unmapped names stay canonical"
cat > "$FIX/map.yml" <<'EOF'
labels:
  in-review: "status: in review"
  ready-for-human: "status: needs human"
EOF
[ "$(run_lib "$FIX/map.yml" 'label_for in-review')" = "status: in review" ] \
  && ok "mapped name resolves" || bad "mapped name did not resolve"
[ "$(run_lib "$FIX/map.yml" 'label_for wontfix')" = "wontfix" ] \
  && ok "unmapped name stays canonical" || bad "unmapped name changed"
# Capture first: grep -q would close the pipe early and pipefail would read
# the producer's SIGPIPE as a test failure.
axis="$(run_lib "$FIX/map.yml" 'state_labels_resolved')"
printf '%s\n' "$axis" | grep -Fxq "status: needs human" \
  && ok "resolved state axis contains mapped string" || bad "mapped string missing from axis"

case_banner "unknown canonical name is a loud error"
run_lib "$FIX/map.yml" 'label_for not-a-label' >/dev/null 2>&1 \
  && bad "unknown canonical accepted" || ok "unknown canonical rejected"

case_banner "labels: with an unknown key fails config_load"
printf 'labels:\n  bogus-name: x\n' > "$FIX/badkey.yml"
run_lib "$FIX/badkey.yml" 'config_load' >/dev/null 2>&1 \
  && bad "unknown key accepted" || ok "unknown key rejected"

case_banner "remapping a workflow-trigger label fails (v1 constraint)"
printf 'labels:\n  ready-for-agent: go\n' > "$FIX/trigger.yml"
run_lib "$FIX/trigger.yml" 'config_load' >/dev/null 2>&1 \
  && bad "trigger remap accepted" || ok "ready-for-agent remap rejected"
printf 'labels:\n  agent-working: busy\n' > "$FIX/trigger2.yml"
run_lib "$FIX/trigger2.yml" 'config_load' >/dev/null 2>&1 \
  && bad "trigger remap accepted" || ok "agent-working remap rejected"
printf 'labels:\n  agent: bot\n' > "$FIX/trigger3.yml"
run_lib "$FIX/trigger3.yml" 'config_load' >/dev/null 2>&1 \
  && bad "trigger remap accepted" || ok "agent remap rejected"

case_banner "two canonical names resolving to one string fails"
printf 'labels:\n  in-review: same\n  ready-for-human: same\n' > "$FIX/dupe.yml"
run_lib "$FIX/dupe.yml" 'config_load' >/dev/null 2>&1 \
  && bad "collision accepted" || ok "direct collision rejected"
# Collision with another axis' canonical name (in-review -> "bug").
printf 'labels:\n  in-review: bug\n' > "$FIX/dupe2.yml"
run_lib "$FIX/dupe2.yml" 'config_load' >/dev/null 2>&1 \
  && bad "cross-axis collision accepted" || ok "cross-axis collision rejected"

case_banner "empty config file -> defaults (fetch-miss writes an empty file)"
: > "$FIX/empty.yml"
[ "$(run_lib "$FIX/empty.yml" 'label_for in-review')" = "in-review" ] \
  && ok "empty file behaves as no config" || bad "empty file broke defaults"

case_banner "non-label keys are untouched by mapping"
[ "$(run_lib "$FIX/map.yml" 'config_max_concurrent')" = "3" ] \
  && ok "max_concurrent default intact" || bad "unrelated key broken"

case_banner "state transitions skip a CLOSED issue (mediamtx-connect#295)"
run_state() { ( . "$_dir/../scripts/lib/state.sh" 2>/dev/null || exit 90; eval "$1" ) }
[ "$(run_state 'state_transition_action OPEN')" = "apply" ] \
  && ok "OPEN -> apply" || bad "open issue not transitioned"
[ "$(run_state 'state_transition_action CLOSED')" = "skip" ] \
  && ok "CLOSED -> skip (a shipped issue is not handed back)" || bad "closed issue stamped"
# Fail toward acting: refusing to move a live issue on a transient API error
# strands it, which is worse than a stray label on a closed one.
[ "$(run_state 'state_transition_action ""')" = "apply" ] \
  && ok "unreadable state -> apply" || bad "empty state skipped the transition"
[ "$(run_state 'state_transition_action closed')" = "apply" ] \
  && ok "only a definite CLOSED skips" || bad "lowercase matched the skip"

case_banner "a queued implement re-checks for an open agent PR (the #324 race)"
run_common() { ( . "$_dir/../scripts/lib/common.sh" 2>/dev/null || exit 90; eval "$1" ) }
branches() { printf 'agent/issue-304\nagent/issue-295-r2\nagent/issue-12\n'; }
branches | run_common 'sh_has_agent_pr_for_issue 295' \
  && ok "a retry branch counts as this issue's PR" || bad "-rK branch missed"
printf 'agent/issue-295\n' | run_common 'sh_has_agent_pr_for_issue 295' \
  && ok "the plain branch counts" || bad "plain branch missed"
printf 'agent/issue-304\nagent/issue-12\n' | run_common 'sh_has_agent_pr_for_issue 295' \
  && bad "matched an unrelated issue" || ok "unrelated issues do not match"
# The prefix trap: #29 must not be seen as #295's PR, nor #2950 as #295's.
printf 'agent/issue-2950\n' | run_common 'sh_has_agent_pr_for_issue 295' \
  && bad "matched a longer issue number" || ok "#2950 is not #295"
printf '' | run_common 'sh_has_agent_pr_for_issue 295' \
  && bad "matched with no open PRs" || ok "no open agent PRs -> fresh dispatch"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
