#!/usr/bin/env bash
# test-claude-run.sh — fixture tests for the result-JSON accessors in
# lib/claude-run.sh. Pure logic only (no CLI, no network).
#
# claude_result_digest earns its own test: it swallows jq errors by design
# (`2>/dev/null || true`), so a broken expression degrades to an empty line
# rather than a failure — and on a give-up that line is the only surviving
# evidence of what the run did. Silent breakage there is the exact failure
# mode the digest exists to prevent.
# Run: tests/test-claude-run.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR="$_dir/../scripts/lib/claude-run.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-claude-run.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

run() { # helper args...
  ( SMALLHOURS_CONFIG="$FIX/definitely-absent.yml"; unset GITHUB_WORKSPACE
    . "$CR" 2>/dev/null || exit 90
    "$@" )
}

# The shape claude -p --output-format json writes when it burns its turn cap —
# the case that stranded mediamtx-connect#213 with no diagnosable trace.
cat > "$FIX/max-turns.json" <<'EOF'
{"type":"result","subtype":"error_max_turns","is_error":true,
 "duration_ms":278512,"duration_api_ms":250100,"num_turns":50,
 "session_id":"abc-123","total_cost_usd":1.2345,
 "usage":{"input_tokens":10000,"output_tokens":20000}}
EOF

cat > "$FIX/clean.json" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"duration_ms":29000,
 "num_turns":5,"total_cost_usd":0.12,"result":"Did the thing.",
 "usage":{"input_tokens":100,"output_tokens":200}}
EOF

# An aborted run can flush only part of the object.
printf '%s\n' '{"subtype":"error_during_execution","is_error":true}' > "$FIX/partial.json"
: > "$FIX/empty.json"
printf 'not json at all\n' > "$FIX/malformed.json"

case_banner "digest carries the counters that distinguish give-ups"
d="$(run claude_result_digest "$FIX/max-turns.json")"
[ "$(jq -r .num_turns <<< "$d")"      = "50" ]                && ok "num_turns surfaced"     || bad "num_turns missing: $d"
[ "$(jq -r .subtype <<< "$d")"        = "error_max_turns" ]   && ok "subtype surfaced"       || bad "subtype missing: $d"
[ "$(jq -r .duration_ms <<< "$d")"    = "278512" ]            && ok "duration surfaced"      || bad "duration missing: $d"
[ "$(jq -r .total_cost_usd <<< "$d")" = "1.2345" ]            && ok "cost surfaced"          || bad "cost missing: $d"
[ "$(jq -r .input_tokens <<< "$d")"   = "10000" ]             && ok "input tokens flattened" || bad "input tokens missing: $d"
[ "$(jq -r .output_tokens <<< "$d")"  = "20000" ]             && ok "output tokens flattened"|| bad "output tokens missing: $d"
[ "$(jq -r 'has("result")' <<< "$d")" = "false" ]             && ok "agent summary excluded (it goes on the issue)" || bad "result text leaked into the digest"
[ "$(printf '%s' "$d" | wc -l)" -eq 0 ]                       && ok "single line (one log entry)" || bad "digest spans lines"

case_banner "is_error false is kept, absent fields are dropped"
d="$(run claude_result_digest "$FIX/clean.json")"
[ "$(jq -r .is_error <<< "$d")" = "false" ] && ok "is_error:false survives the null filter" || bad "false dropped as null: $d"
d="$(run claude_result_digest "$FIX/partial.json")"
[ "$(jq -r 'has("num_turns")' <<< "$d")" = "false" ] && ok "absent counter omitted, not null" || bad "null key emitted: $d"
[ "$(jq -r .subtype <<< "$d")" = "error_during_execution" ] && ok "partial result still digests" || bad "partial lost: $d"

case_banner "unreadable input degrades quietly (never fails the give-up path)"
[ -z "$(run claude_result_digest "$FIX/empty.json")" ]     && ok "empty file -> empty digest"     || bad "empty file produced output"
[ -z "$(run claude_result_digest "$FIX/malformed.json")" ] && ok "malformed file -> empty digest" || bad "malformed file produced output"
[ -z "$(run claude_result_digest "$FIX/nope.json")" ]      && ok "missing file -> empty digest"   || bad "missing file produced output"
run claude_result_digest "$FIX/malformed.json" >/dev/null 2>&1 \
  && ok "returns success (a broken digest must not mask the real give-up)" \
  || bad "non-zero exit would abort the give-up handler"

case_banner "field accessors still read the documented shape"
[ "$(run claude_is_error "$FIX/max-turns.json")"  = "true" ]           && ok "claude_is_error"    || bad "is_error accessor"
[ "$(run claude_num_turns "$FIX/max-turns.json")" = "50" ]             && ok "claude_num_turns"   || bad "num_turns accessor"
[ "$(run claude_result_text "$FIX/clean.json")"   = "Did the thing." ] && ok "claude_result_text" || bad "result_text accessor"
[ -z "$(run claude_result_text "$FIX/max-turns.json")" ] \
  && ok "no result text on a max-turns give-up (why the fallback reason exists)" \
  || bad "result text unexpectedly present"

echo
echo "test-claude-run: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
