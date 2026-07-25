#!/usr/bin/env bash
# test-edges.sh — fixture tests for the pure edge-graph functions (06-2/06-3,
# ADR 0006): ref parsing, promotable computation, plan-change detection, cycle
# detection. No gh, no network. Run: tests/test-edges.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/../scripts/lib/edges.sh"

pass=0 fail=0
eq() { # description want got
  if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "  ok: $1"
  else fail=$((fail+1)); printf '  FAIL: %s\n    want: %q\n    got:  %q\n' "$1" "$2" "$3"; fi
}

echo "case: edges_blocked_by_refs"
body='Intro text.

## Blocked by

- #7
* #8 label-mapping ticket
- https://github.com/o/r/issues/9
- https://github.com/other/repo/issues/3
- not-a-ref
not a list line

## Delivers

- #99 this is NOT an edge (different section)'
eq "full section parse" \
   "$(printf 'ok:7\nok:8\nok:9\nbad:https://github.com/other/repo/issues/3\nbad:not-a-ref')" \
   "$(printf '%s\n' "$body" | edges_blocked_by_refs o/r)"
eq "no section -> no refs" "" "$(printf 'Just a body.\n- #4\n' | edges_blocked_by_refs o/r)"
eq "malformed number is bad" "bad:#12abc" "$(printf '## Blocked by\n- #12abc\n' | edges_blocked_by_refs o/r)"
eq "case-insensitive heading" "ok:5" "$(printf '## blocked by\n- #5\n' | edges_blocked_by_refs o/r)"

echo "case: edges_promotable"
entries='[
  {"number": 1, "bad": false, "blocked_by": []},
  {"number": 2, "bad": false, "blocked_by": [{"number": 1, "state": "open",   "state_reason": null}]},
  {"number": 3, "bad": false, "blocked_by": [{"number": 1, "state": "closed", "state_reason": "completed"}]},
  {"number": 4, "bad": false, "blocked_by": [{"number": 1, "state": "closed", "state_reason": "not_planned"}]},
  {"number": 5, "bad": true,  "blocked_by": []},
  {"number": 6, "bad": false, "blocked_by": [{"number": 1, "state": "closed", "state_reason": "completed"},
                                             {"number": 2, "state": "open",   "state_reason": null}]}
]'
eq "no edges + all-cleared promote; open/not_planned/bad/mixed do not" \
   "$(printf '1\n3')" "$(edges_promotable <<< "$entries")"

echo "case: edges_plan_changed"
eq "not_planned blocker flags its dependent" \
   "$(printf '4\t#1 ')" "$(edges_plan_changed <<< "$entries")"
eq "bad issues are skipped" "" \
   "$(edges_plan_changed <<< '[{"number":9,"bad":true,"blocked_by":[{"number":1,"state":"closed","state_reason":"not_planned"}]}]')"

echo "case: edges_cycle_members"
eq "two-node cycle" "$(printf '10\n11')" \
   "$(edges_cycle_members <<< '{"10":["11"],"11":["10"]}')"
eq "chain is not a cycle" "" \
   "$(edges_cycle_members <<< '{"10":["11"],"11":["12"],"12":[]}')"
eq "self-loop" "7" "$(edges_cycle_members <<< '{"7":["7"]}')"
eq "cycle plus tail ejects only members" "$(printf '1\n2\n3')" \
   "$(edges_cycle_members <<< '{"1":["2"],"2":["3"],"3":["1"],"4":["1"]}')"
eq "edge to unknown node is a dead end" "" \
   "$(edges_cycle_members <<< '{"5":["99"]}')"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
