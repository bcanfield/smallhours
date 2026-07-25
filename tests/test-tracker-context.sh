#!/usr/bin/env bash
# test-tracker-context.sh — fixture tests for the pure spec-ref parser (06-4,
# ADR 0006). No gh, no network. Run: tests/test-tracker-context.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/../scripts/lib/tracker-context.sh"

pass=0 fail=0
check() { # description expected body...
  local desc="$1" want="$2" got
  got="$(printf '%s\n' "$3" | tc_spec_ref)"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok: $desc"
  else fail=$((fail+1)); echo "  FAIL: $desc — want '$want' got '$got'"; fi
}

check "issue ref"                 "issue:12"        'Some intro.
Spec: #12
More text.'
check "repo file path"            "file:docs/specs/auth.md" 'Spec: docs/specs/auth.md'
check "markdown link to file"     "file:docs/specs/auth.md" 'Spec: [the spec](docs/specs/auth.md)'
check "full issue URL"            "issue:34"        'Spec: https://github.com/o/r/issues/34'
check "first Spec line wins"      "issue:1"         'Spec: #1
Spec: #2'
check "no Spec line -> nothing"   ""                'Just a plain grilled issue.
## Blocked by
- #3'
check "foreign URL -> nothing"    ""                'Spec: https://example.com/doc'
check "trailing text ignored"     "issue:7"         'Spec: #7 (the umbrella spec)'
check "lowercase spec:"           "issue:9"         'spec: #9'
check "not-a-number hash"         ""                'Spec: #12abc'
check "mid-line mention ignored"  ""                'See the Spec: #4 note above'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
