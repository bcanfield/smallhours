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

# The shape a long, mostly-cached run actually writes (mediamtx-connect#211):
# tiny input_tokens/output_tokens next to a 76-turn count read as "died doing
# nothing" when the real story — 62k+ tokens/turn, almost all cache reads — is
# sitting in the two fields the old digest never surfaced.
cat > "$FIX/cache-heavy.json" <<'EOF'
{"type":"result","subtype":"error_max_turns","is_error":true,
 "duration_ms":885911,"num_turns":76,"total_cost_usd":4.5073,
 "usage":{"input_tokens":208,"output_tokens":62493,
  "cache_creation_input_tokens":18000,"cache_read_input_tokens":4200000}}
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
[ "$(jq -r .total_tokens <<< "$d")"   = "30000" ]             && ok "total_tokens sums input+output" || bad "total_tokens wrong: $d"
[ "$(jq -r .tokens_per_turn <<< "$d")" = "600" ]              && ok "tokens_per_turn = total/num_turns" || bad "tokens_per_turn wrong: $d"
[ "$(jq -r 'has("result")' <<< "$d")" = "false" ]             && ok "agent summary excluded (it goes on the issue)" || bad "result text leaked into the digest"
[ "$(printf '%s' "$d" | wc -l)" -eq 0 ]                       && ok "single line (one log entry)" || bad "digest spans lines"

d="$(run claude_result_digest "$FIX/cache-heavy.json")"
[ "$(jq -r .cache_creation_input_tokens <<< "$d")" = "18000" ]   && ok "cache_creation_input_tokens surfaced" || bad "cache_creation missing: $d"
[ "$(jq -r .cache_read_input_tokens <<< "$d")"     = "4200000" ] && ok "cache_read_input_tokens surfaced"     || bad "cache_read missing: $d"
[ "$(jq -r .total_tokens <<< "$d")" = "4280701" ] \
  && ok "total_tokens includes cache tokens (the turn count's real backing)" || bad "total_tokens wrong: $d"
[ "$(jq -r .tokens_per_turn <<< "$d")" = "56325" ] \
  && ok "tokens_per_turn shows the run was cache-heavy, not idle, despite tiny input_tokens" || bad "tokens_per_turn wrong: $d"

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

# The reason that reaches the issue/PR. The whole point is that a give-up with
# no `.result` must still say something a maintainer can act on WITHOUT opening
# the Actions tab — six mediamtx-connect handbacks read "failed before
# producing a result" when the machine knew it was a turn-cap exhaustion.
case_banner "give-up reason: agent summary when there is one, synthesized when there isn't"
[ "$(run claude_give_up_reason "$FIX/clean.json" implement)" = "Did the thing." ] \
  && ok "agent's own summary wins over anything synthesized" || bad "result text not preferred: $(run claude_give_up_reason "$FIX/clean.json" implement)"

r="$(run claude_give_up_reason "$FIX/max-turns.json" implement)"
case "$r" in *"50 turns"*)     ok "max-turns reason carries the turn count" ;; *) bad "turn count missing: $r" ;; esac
case "$r" in *"cap 100"*)      ok "max-turns reason carries the configured cap" ;; *) bad "cap missing: $r" ;; esac
case "$r" in *'`max_turns.implement`'*) ok "names the exact config knob to raise" ;; *) bad "knob not named: $r" ;; esac
case "$r" in *"workflow logs"*) bad "still punts to the logs when the cause is known" ;; *) ok "does not punt to the job log" ;; esac

# A cap exhaustion in a different stage must name THAT stage's knob and cap,
# not implement's — the remedy is stage-specific (mediamtx-connect#209 hit
# auto_fix's cap, not implement's).
r="$(run claude_give_up_reason "$FIX/max-turns.json" auto_fix)"
case "$r" in *'`max_turns.auto_fix`'*) ok "knob is per-stage" ;; *) bad "wrong stage knob: $r" ;; esac
case "$r" in *"cap 40"*)               ok "cap is read per-stage" ;; *) bad "wrong stage cap: $r" ;; esac

# Any other error subtype is still more informative than the bare fallback.
r="$(run claude_give_up_reason "$FIX/partial.json" implement)"
case "$r" in *"error_during_execution"*) ok "other subtypes are named verbatim" ;; *) bad "subtype dropped: $r" ;; esac

# No terminal event at all (CLI died before flushing) — nothing to synthesize
# from, so the original fallback is still the honest answer.
[ "$(run claude_give_up_reason "$FIX/empty.json" implement)" = "the agent run failed before producing a result (see workflow logs)" ] \
  && ok "no result JSON -> unchanged fallback" || bad "empty result reason wrong: $(run claude_give_up_reason "$FIX/empty.json" implement)"
[ "$(run claude_give_up_reason "$FIX/nope.json" implement)" = "the agent run failed before producing a result (see workflow logs)" ] \
  && ok "missing result file -> unchanged fallback" || bad "missing result reason wrong"
[ -n "$(run claude_give_up_reason "$FIX/malformed.json" implement)" ] \
  && ok "malformed result still yields a postable reason" || bad "malformed result produced an empty comment body"

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

# ── Wall-clock budget + the timeout give-up (ADR 0007) ───────────────────────
# The budget is DERIVED (cap - elapsed - tail) so that provisioning overrun
# eats the agent's time instead of the tail that has to survive a timeout.
# These cases pin the derivation, because getting it wrong is invisible until
# a real run is cancelled and leaves nothing behind — the exact failure the
# whole mechanism exists to prevent.
case_banner "wall-clock budget derivation"
# The budget is only meaningful where GNU `timeout` exists, and it deliberately
# degrades to uncapped where it doesn't. Neither branch may depend on whatever
# the HOST happens to have, so both are driven from a controlled PATH: a stub
# `timeout` for the derivation cases, an empty bin for the fallback case.
mkdir -p "$FIX/withtimeout" "$FIX/notimeout"
printf '#!/bin/sh\nexit 0\n' > "$FIX/withtimeout/timeout"; chmod +x "$FIX/withtimeout/timeout"
budget() { # cap start tail
  ( export SMALLHOURS_JOB_CAP_MINUTES="$1" SMALLHOURS_JOB_START_EPOCH="$2" SMALLHOURS_TAIL_SECONDS="$3"
    export PATH="$FIX/withtimeout:$PATH"
    run claude_run_budget_seconds )
}
now="$(date +%s)"
# The function reads its own `date`, so a second can tick between $now and the
# call. Assert within 2s rather than writing a test that fails 1 run in 60.
near() { # description want got tolerance
  local d=$(( $3 - $2 )); [ "$d" -lt 0 ] && d=$(( -d ))
  if [ "$d" -le "$4" ]; then ok "$1"; else bad "$1 (want ~$2, got $3)"; fi
}
[ -z "$(budget "" "" "")" ] && ok "no cap -> no timeout (standalone/self-hosted stays runnable)" || bad "uncapped run produced a budget"
near "fresh job: cap*60 - 0 elapsed - tail" 3510 "$(budget 60 "$now" 90)" 2
near "5m of provisioning comes out of the agent's time, not the tail" 3210 "$(budget 60 "$((now - 300))" 90)" 2
[ "$(budget 60 "$((now - 3600))" 90)" = "60" ] \
  && ok "provisioning ate the job -> floor, so a short give-up still beats a cancellation" || bad "floor wrong: $(budget 60 "$((now - 3600))" 90)"
near "clock skew (start in the future) reads as 0 elapsed, never a bonus" 3510 "$(budget 60 "$((now + 600))" 90)" 2
[ -z "$(budget "not-a-number" "$now" 90)" ] && ok "non-numeric cap -> uncapped, not a crash" || bad "bad cap did not degrade"
near "unparseable start -> 0 elapsed" 3510 "$(budget 60 "garbage" 90)" 2
# A host without GNU coreutils (macOS, busybox self-hosted) must run UNCAPPED,
# not fail every stage with an inscrutable exit 127 from a missing binary.
no_timeout_budget="$( export SMALLHOURS_JOB_CAP_MINUTES=60 SMALLHOURS_JOB_START_EPOCH="$now" SMALLHOURS_TAIL_SECONDS=90
                      export PATH="$FIX/notimeout"; run claude_run_budget_seconds 2>/dev/null )"
[ -z "$no_timeout_budget" ] && ok "no \`timeout\` on PATH -> uncapped, never a hard failure" || bad "missing timeout still produced a budget: $no_timeout_budget"

# A real SIGTERM'd run leaves a stream with no terminal event. Two assistant
# turns stand in for "it was working when the clock stopped it".
printf '%s\n%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"a.ts","old_string":"a","new_string":"b"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pnpm test"}}]}}' \
  > "$FIX/truncated-stream.jsonl"

case_banner "synthesized terminal result for a run the CLI never got to end"
s="$(run _claude_synthesize_timeout_result "$FIX/truncated-stream.jsonl" 3510 3510000)"
[ "$(jq -r .subtype <<< "$s")"     = "error_timeout" ] && ok "subtype is error_timeout"  || bad "subtype wrong: $s"
[ "$(jq -r .is_error <<< "$s")"    = "true" ]          && ok "is_error true (a give-up)" || bad "is_error wrong: $s"
[ "$(jq -r .type <<< "$s")"        = "result" ]        && ok "shaped like a real terminal event" || bad "type wrong: $s"
[ "$(jq -r .num_turns <<< "$s")"   = "2" ]             && ok "turns recovered from the truncated stream" || bad "num_turns wrong: $s"
[ "$(jq -r ._synthesized <<< "$s")" = "true" ]         && ok "marked synthesized (never mistaken for CLI output)" || bad "not marked: $s"
[ -n "$(run claude_result_digest <(printf '%s\n' "$s"))" ] && ok "digests like any other result" || bad "digest could not read it"
s="$(run _claude_synthesize_timeout_result "$FIX/nope.jsonl" 3510 3510000)"
[ "$(jq -r .num_turns <<< "$s")" = "0" ] && ok "missing stream -> 0 turns, still a valid result" || bad "missing stream broke synthesis: $s"

# The whole point of synthesizing: without it this falls into the bare
# "failed before producing a result" arm — verbatim the defect that arm was
# written to eliminate, reintroduced under a new subtype.
cat > "$FIX/timeout.json" <<'EOF'
{"type":"result","subtype":"error_timeout","is_error":true,
 "num_turns":58,"duration_ms":3510000,"budget_seconds":3510,"_synthesized":true}
EOF
case_banner "give-up reason for a wall-clock exhaustion"
r="$(run claude_give_up_reason "$FIX/timeout.json" implement)"
case "$r" in *"58 turns"*)       ok "carries the turn count (thrashing vs grinding)" ;; *) bad "turn count missing: $r" ;; esac
case "$r" in *"58m"*)            ok "carries the elapsed minutes" ;; *) bad "duration missing: $r" ;; esac
case "$r" in *"Split it"*)       ok "prescribes the only remedy there is" ;; *) bad "no remedy given: $r" ;; esac
case "$r" in *'max_turns'*|*'.smallhours.yml'*) bad "names a knob that cannot fix a timeout: $r" ;; *) ok "names no config knob (the budget is not consumer-tunable)" ;; esac
case "$r" in *"workflow logs"*)  bad "punts to the logs when the cause is known: $r" ;; *) ok "does not punt to the job log" ;; esac

echo
echo "test-claude-run: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
