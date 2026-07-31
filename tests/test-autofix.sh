#!/usr/bin/env bash
# test-autofix.sh — fixture-driven tests for the CI auto-fix stage (T3'/T4).
# Pure logic only (no gh, no network):
#   - the label->attempt parse in lib/state.sh and attempt_cap in lib/config.sh
#   - what a CLEAN WORKING TREE means, in lib/autofix.sh (ADR 0009)
#   - the conventional-commit PR title in lib/config.sh — the title that stops
#     an auto-fix attempt being spent on a prefix in the first place
# The last two are two halves of one problem (#30): a PR title that cost an
# attempt and then a hand-off, on code that was already green.
# Run: tests/test-autofix.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$_dir/../scripts/lib/state.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-autofix.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# Pure and dependency-free, so it sources straight into the test process.
. "$_dir/../scripts/lib/autofix.sh"

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

# parse <newline-separated labels> — prints the attempt count the parser sees.
# Sourced in a subshell so the config cache never leaks between cases.
parse() {
  local labels="$1" cfg="${2:-}"
  ( SMALLHOURS_CONFIG="${cfg:-$FIX/definitely-absent.yml}"; unset GITHUB_WORKSPACE
    . "$STATE" 2>/dev/null || exit 90
    printf '%s\n' "$labels" | state_autofix_attempt_from_labels )
}

cap() { # attempt_cap through a config fixture (empty path -> defaults)
  local cfg="${1:-}"
  ( SMALLHOURS_CONFIG="${cfg:-$FIX/definitely-absent.yml}"; unset GITHUB_WORKSPACE
    . "$STATE" 2>/dev/null || exit 90
    config_attempt_cap )
}

case_banner "no attempt labels -> 0"
[ "$(parse "")" = "0" ] && ok "empty label list is attempt 0" || bad "empty list not 0"
[ "$(parse $'agent\nci-failing\nbug')" = "0" ] \
  && ok "unrelated labels ignored" || bad "unrelated labels counted"

case_banner "attempt labels parse to their number"
[ "$(parse $'agent\nautofix-attempt-1')" = "1" ] \
  && ok "attempt-1 -> 1" || bad "attempt-1 misparsed"
[ "$(parse $'autofix-attempt-3\nci-failing')" = "3" ] \
  && ok "attempt-3 -> 3" || bad "attempt-3 misparsed"

case_banner "drift heals toward the highest attempt present"
[ "$(parse $'autofix-attempt-1\nautofix-attempt-3')" = "3" ] \
  && ok "multiple attempt labels -> highest wins" || bad "highest attempt not chosen"
[ "$(parse $'autofix-attempt-9\nautofix-attempt-10')" = "10" ] \
  && ok "numeric (not lexical) comparison" || bad "10 lost to 9 — lexical sort"

case_banner "near-miss label names never count"
[ "$(parse $'autofix-attempt-\nautofix-attempt-x\nmy-autofix-attempt-2\nautofix-attempt-2-old')" = "0" ] \
  && ok "malformed/prefixed/suffixed names ignored" || bad "near-miss name counted"

case_banner "attempt_cap: default and override"
[ "$(cap)" = "3" ] && ok "default attempt_cap is 3" || bad "default cap wrong"
cat > "$FIX/cap.yml" <<'EOF'
attempt_cap: 1
EOF
[ "$(cap "$FIX/cap.yml")" = "1" ] && ok "attempt_cap: 1 honoured" || bad "cap override ignored"
cat > "$FIX/cap0.yml" <<'EOF'
attempt_cap: 0
EOF
[ "$(cap "$FIX/cap0.yml")" = "0" ] \
  && ok "attempt_cap: 0 (auto-fix disabled) honoured" || bad "cap 0 ignored"

# ── The clean-tree decision (ADR 0009) ───────────────────────────────────────
# Fixtures are statusCheckRollup arrays as `gh pr view --json` returns them.
ROLLUP_RED='[{"name":"Build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-30T10:00:00Z","completedAt":"2026-07-30T10:04:00Z"},
             {"name":"Conventional commit format","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-30T10:00:00Z","completedAt":"2026-07-30T10:01:00Z"}]'
# Same jobs, re-run after a retitle: identical names and conclusions, new times.
ROLLUP_RERUN='[{"name":"Build","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-07-30T10:20:00Z","completedAt":"2026-07-30T10:20:10Z"},
               {"name":"Conventional commit format","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-30T10:20:00Z","completedAt":"2026-07-30T10:21:00Z"}]'
ROLLUP_QUEUED='[{"name":"Build","status":"QUEUED","conclusion":null,"startedAt":null,"completedAt":null}]'
ROLLUP_LEGACY='[{"context":"ci/legacy","state":"FAILURE","createdAt":"2026-07-30T10:00:00Z"}]'

digest() { autofix_checks_digest <<< "$1"; }

case_banner "checks digest: only real movement changes it"
[ "$(digest "$ROLLUP_RED")" = "$(digest "$ROLLUP_RED")" ] \
  && ok "same rollup -> same digest" || bad "digest is not stable"
[ "$(digest "$ROLLUP_RED")" != "$(digest "$ROLLUP_RERUN")" ] \
  && ok "a re-run of the same jobs is visible" || bad "re-run looked identical"
[ "$(digest '[]')" = "$(digest '[]')" ] \
  && ok "empty rollup digests equally" || bad "empty rollup unstable"
[ -n "$(digest "$ROLLUP_LEGACY")" ] \
  && ok "legacy commit-status shape digests" || bad "legacy status shape lost"
# Order is GitHub's business, not a signal.
[ "$(digest "$ROLLUP_RED")" = "$(digest "$(jq -c 'reverse' <<< "$ROLLUP_RED")")" ] \
  && ok "digest is order-independent" || bad "rollup order leaked into the digest"

case_banner "checks pending: what is still in flight"
[ "$(autofix_checks_pending <<< "$ROLLUP_RED")" = "0" ] \
  && ok "all-completed rollup has none pending" || bad "completed counted as pending"
[ "$(autofix_checks_pending <<< "$ROLLUP_QUEUED")" = "1" ] \
  && ok "a queued check counts" || bad "queued check missed"
[ "$(autofix_checks_pending <<< '[{"name":"a","status":"in_progress"}]')" = "1" ] \
  && ok "status casing does not matter" || bad "lowercase status missed"
[ "$(autofix_checks_pending <<< '[]')" = "0" ] \
  && ok "empty rollup has none pending" || bad "empty rollup miscounted"

case_banner "ci_moved: an event is coming, or already fired"
[ "$(autofix_ci_moved a a 0)" = "false" ] \
  && ok "nothing changed, nothing running -> false" || bad "false movement reported"
[ "$(autofix_ci_moved a a 2)" = "true" ] \
  && ok "checks in flight -> true" || bad "in-flight checks missed"
[ "$(autofix_ci_moved a b 0)" = "true" ] \
  && ok "digest changed -> true" || bad "digest change missed"
[ "$(autofix_ci_moved a a '')" = "false" ] \
  && ok "an unreadable pending count is not movement" || bad "empty count misread"

case_banner "clean-tree outcome"
[ "$(autofix_clean_tree_outcome false true)" = "out-of-tree" ] \
  && ok "CI moving is a repair, commit or not" || bad "out-of-tree repair missed"
[ "$(autofix_clean_tree_outcome true true)" = "out-of-tree" ] \
  && ok "retitle + live CI -> out-of-tree" || bad "retitle with CI misrouted"
[ "$(autofix_clean_tree_outcome true false)" = "stranded" ] \
  && ok "retitle nothing re-checks -> stranded" || bad "stranded case misrouted"
[ "$(autofix_clean_tree_outcome false false)" = "no-changes" ] \
  && ok "a PR that did not move at all -> no-changes" || bad "no-changes case lost"

# ── Conventional-commit PR title (the prevention half) ───────────────────────
# title <config> <issue-title>  — issue labels on stdin, one per line.
title() {
  local cfg="$1" t="$2"
  ( SMALLHOURS_CONFIG="${cfg:-$FIX/definitely-absent.yml}"; unset GITHUB_WORKSPACE
    . "$STATE" 2>/dev/null || exit 90
    config_pr_title "$t" )
}

cat > "$FIX/types.yml" <<'EOF'
conventional_title_types:
  bug: fix
  enhancement: feat
EOF

case_banner "no map configured -> the issue title, verbatim"
[ "$(printf 'bug\n' | title "" "Record toggle has no pending state")" \
  = "Record toggle has no pending state" ] \
  && ok "unconfigured consumers are untouched" || bad "title changed with no map"

case_banner "a mapped label supplies the type"
[ "$(printf 'bug\n' | title "$FIX/types.yml" "Record toggle has no pending state")" \
  = "fix: Record toggle has no pending state" ] \
  && ok "bug -> fix:" || bad "bug did not map to fix"
[ "$(printf 'enhancement\n' | title "$FIX/types.yml" "Add a stream filter")" \
  = "feat: Add a stream filter" ] \
  && ok "enhancement -> feat:" || bad "enhancement did not map to feat"

case_banner "an unmapped issue is left alone, never guessed"
[ "$(printf 'question\n' | title "$FIX/types.yml" "Why is the toggle slow")" \
  = "Why is the toggle slow" ] \
  && ok "no label maps -> verbatim (a guessed type drops the release)" \
  || bad "invented a type from nothing"
[ "$(printf '' | title "$FIX/types.yml" "Untriaged work")" = "Untriaged work" ] \
  && ok "no labels at all -> verbatim" || bad "labelless issue got a prefix"

case_banner "a title that is already conventional is never re-prefixed"
for t in "fix: already right" "fix(streams): scoped" "feat!: breaking" \
         "fix(streams)!: both" "Fix: capitalised"; do
  [ "$(printf 'bug\n' | title "$FIX/types.yml" "$t")" = "$t" ] \
    && ok "left alone: $t" || bad "re-prefixed: $t"
done
# The trap this walked into: prose before a colon is NOT a type.
[ "$(printf 'bug\n' | title "$FIX/types.yml" "Streams: record toggle broken")" \
  = "fix: Streams: record toggle broken" ] \
  && ok "prose before a colon still gets a type" || bad "'Streams:' read as a type"
# A standard type the consumer did not declare still counts as one.
[ "$(printf 'bug\n' | title "$FIX/types.yml" "docs: fix a typo")" = "docs: fix a typo" ] \
  && ok "undeclared standard type recognised" || bad "docs: got double-prefixed"

case_banner "keys resolve through the labels: mapping"
cat > "$FIX/remapped.yml" <<'EOF'
labels:
  bug: "type:bug"
conventional_title_types:
  bug: fix
EOF
[ "$(printf 'type:bug\n' | title "$FIX/remapped.yml" "Toggle is broken")" \
  = "fix: Toggle is broken" ] \
  && ok "canonical key matches the repo's own label string" || bad "remapped label missed"
[ "$(printf 'bug\n' | title "$FIX/remapped.yml" "Toggle is broken")" \
  = "Toggle is broken" ] \
  && ok "the pre-remap label no longer matches" || bad "unmapped label still matched"

case_banner "non-canonical keys and config order"
cat > "$FIX/order.yml" <<'EOF'
conventional_title_types:
  docs: docs
  bug: fix
EOF
[ "$(printf 'docs\n' | title "$FIX/order.yml" "Explain the sweep")" \
  = "docs: Explain the sweep" ] \
  && ok "a label outside the toolkit vocabulary works" || bad "non-canonical key ignored"
[ "$(printf 'bug\ndocs\n' | title "$FIX/order.yml" "Explain the sweep")" \
  = "docs: Explain the sweep" ] \
  && ok "config order breaks the tie" || bad "tie-break was not config order"

echo
echo "test-autofix: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
