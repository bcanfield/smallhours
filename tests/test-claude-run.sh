#!/usr/bin/env bash
# test-claude-run.sh — fixture tests for the result-JSON accessors in
# lib/claude-run.sh. Pure logic only (no CLI, no network).
#
# claude_result_digest earns its own test: it swallows jq errors by design
# (`2>/dev/null || true`), so a broken expression degrades to an empty line
# rather than a failure — and on a give-up that line is the only surviving
# evidence of what the run did. Silent breakage there is the exact failure
# mode the digest exists to prevent.
#
# claude_work_digest/claude_work_summary get the same treatment: they read the
# stream-json event log, the only place tool-use ever appears (the final
# result event never carries it), and must degrade the same way on a
# truncated/malformed stream rather than take down the give-up path with them.
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

# A representative stream-json event log: system init (ignored), two Bash
# calls (one repeated verbatim — dedup should collapse it), one Read (not a
# "touch"), an Edit and a Write, a plain-text assistant turn (no tool_use),
# and the terminal result event (also ignored — tool-use never lives there).
cat > "$FIX/stream.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"s1"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pnpm typecheck"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"apps/web/src/foo.tsx"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"apps/web/src/foo.tsx","old_string":"a","new_string":"b"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"docs/FEATURES.md","content":"..."}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pnpm typecheck"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":6,"duration_ms":9000,"result":"Done.","usage":{"input_tokens":1,"output_tokens":2}}
EOF

: > "$FIX/empty-stream.jsonl"
printf '%s\n{"broken' "$(head -1 "$FIX/stream.jsonl")" > "$FIX/malformed-stream.jsonl"

case_banner "work digest counts tools, dedupes files and commands"
d="$(run claude_work_digest "$FIX/stream.jsonl")"
[ "$(jq -r '.tool_counts.Bash' <<< "$d")"   = "2" ] && ok "Bash counted per call, not deduped"        || bad "Bash count wrong: $d"
[ "$(jq -r '.tool_counts.Edit' <<< "$d")"   = "1" ] && ok "Edit counted"                              || bad "Edit count wrong: $d"
[ "$(jq -r '.tool_counts.Read' <<< "$d")"   = "1" ] && ok "Read counted (but not a file-touch)"       || bad "Read count wrong: $d"
[ "$(jq -r '.files_touched_total' <<< "$d")" = "2" ] \
  && ok "files_touched dedupes Edit+Write, excludes Read" || bad "files_touched_total wrong: $d"
[ "$(jq -r '.files_touched | sort | join(",")' <<< "$d")" = "apps/web/src/foo.tsx,docs/FEATURES.md" ] \
  && ok "files_touched lists the right paths" || bad "files_touched wrong: $d"
[ "$(jq -r '.bash_commands_total' <<< "$d")" = "1" ] && ok "repeated bash command deduped" || bad "bash_commands_total wrong: $d"
[ "$(jq -r 'has("result") or has("usage")' <<< "$d")" = "false" ] \
  && ok "no run metadata leaked into the work digest" || bad "digest carries unrelated fields: $d"

case_banner "work digest caps long lists but keeps the true total (no silent truncation)"
{
  for i in $(seq 1 40); do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"f%02d.txt","old_string":"a","new_string":"b"}}]}}\n' "$i"
  done
  for i in $(seq 1 25); do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cmd-%02d"}}]}}\n' "$i"
  done
} > "$FIX/big-stream.jsonl"
d="$(run claude_work_digest "$FIX/big-stream.jsonl")"
[ "$(jq -r '.files_touched | length' <<< "$d")"  = "30" ] && ok "files_touched capped at 30"       || bad "files cap wrong: $d"
[ "$(jq -r '.files_touched_total' <<< "$d")"      = "40" ] && ok "files_touched_total is the real count, uncapped" || bad "files total wrong: $d"
[ "$(jq -r '.bash_commands | length' <<< "$d")"   = "20" ] && ok "bash_commands capped at 20"      || bad "commands cap wrong: $d"
[ "$(jq -r '.bash_commands_total' <<< "$d")"      = "25" ] && ok "bash_commands_total is the real count, uncapped" || bad "commands total wrong: $d"

case_banner "work digest degrades quietly on empty/malformed/missing streams"
_zero_digest='{"tool_counts":{},"files_touched":[],"files_touched_total":0,"bash_commands":[],"bash_commands_total":0}'
[ "$(run claude_work_digest "$FIX/empty-stream.jsonl")" = "$_zero_digest" ] \
  && ok "empty stream -> all-zero digest, not an error" || bad "empty stream digest wrong: $(run claude_work_digest "$FIX/empty-stream.jsonl")"
[ -z "$(run claude_work_digest "$FIX/malformed-stream.jsonl")" ] && ok "malformed stream -> empty digest" || bad "malformed stream produced output"
# jq -s (slurp) treats an unopenable file as zero documents read rather than
# refusing to evaluate — so a missing stream reads the same as an empty one
# (both mean "no tool-use captured"), unlike the non-slurped claude_result_digest.
[ "$(run claude_work_digest "$FIX/nope.jsonl")" = "$_zero_digest" ] \
  && ok "missing stream -> all-zero digest, same as empty" || bad "missing stream digest wrong: $(run claude_work_digest "$FIX/nope.jsonl")"
run claude_work_digest "$FIX/malformed-stream.jsonl" >/dev/null 2>&1 \
  && ok "returns success (a broken work digest must not mask the real give-up)" \
  || bad "non-zero exit would abort the give-up handler"

case_banner "work summary renders a one-liner, worst offenders first, and degrades quietly"
run claude_work_digest "$FIX/stream.jsonl" > "$FIX/stream.work"
[ "$(run claude_work_summary "$FIX/stream.work")" = "tools: Bash×2 Edit×1 Read×1 Write×1 · files touched: 2 · bash commands: 1" ] \
  && ok "summary line matches the documented format, sorted by count desc" \
  || bad "summary line wrong: $(run claude_work_summary "$FIX/stream.work")"
[ "$(run claude_work_summary "$FIX/empty.json")" = "no tool-use data captured" ] \
  && ok "empty work file -> fallback message"   || bad "empty work file summary wrong"
[ "$(run claude_work_summary "$FIX/nope.work")" = "no tool-use data captured" ] \
  && ok "missing work file -> fallback message" || bad "missing work file summary wrong"
printf '{}\n' > "$FIX/no-tools.work"
[ "$(run claude_work_summary "$FIX/no-tools.work")" = "tools: none · files touched: 0 · bash commands: 0" ] \
  && ok "digest with no tool calls reads as none/0, not blank" || bad "no-tools summary wrong: $(run claude_work_summary "$FIX/no-tools.work")"

echo
echo "test-claude-run: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
