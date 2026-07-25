#!/usr/bin/env bash
# test-autofix.sh — fixture-driven tests for the auto-fix attempt counter
# (T3'/T4, M6). Pure logic only (no gh, no network): the label->attempt parse
# in lib/state.sh and the attempt_cap getter in lib/config.sh.
# Run: tests/test-autofix.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$_dir/../scripts/lib/state.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-autofix.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

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

echo
echo "test-autofix: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
