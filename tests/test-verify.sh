#!/usr/bin/env bash
# test-verify.sh — the verify gate and its re-entry loop (lib/verify.sh).
# No network: `claude` is stubbed on PATH and records how it was invoked.
#
# The properties worth guarding are the ones whose breakage looks like success:
#
#   * a gate that stays red must still return 0, or a lint error becomes a
#     stalled issue — strictly worse than the no-gate behaviour it replaced
#   * re-entry must pass --continue, or the repair agent starts cold and is
#     liable to "fix" the gate by reverting the work
#   * the loop must stop at verify_reentries, or a permanently red command
#     spends the whole wall-clock budget re-entering
#   * SH_VERIFY_FAILED must be set on red and empty on green, because that is
#     the only signal the PR body gets
# Run: tests/test-verify.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$_dir/../scripts/lib/verify.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-verify.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

# A `claude` that records its argv and emits a clean terminal result, so
# claude_run treats it as a successful stage.
mkdir -p "$FIX/bin"
cat > "$FIX/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SH_TEST_CLAUDE_ARGV:?}"
cat > /dev/null
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":2}'
EOF
chmod +x "$FIX/bin/claude"

# Run verify_gate against a config, with a scripted verify command.
# Sets: OUT (stderr log), ARGV (claude invocations), FAILED (SH_VERIFY_FAILED)
gate() { # config-file [home]
  local cfg="$1" home="${2:-$HOME}"
  ARGV="$FIX/argv.$RANDOM"; : > "$ARGV"
  local base="$FIX/result.$RANDOM.json"
  : > "$FIX/unresolved.txt"
  FAILED="$(
    PATH="$FIX/bin:$PATH" \
    SH_TEST_CLAUDE_ARGV="$ARGV" \
    SMALLHOURS_CONFIG="$cfg" \
    CLAUDE_CODE_OAUTH_TOKEN=stub \
    SMALLHOURS_JOB_CAP_MINUTES= \
    HOME="$home" \
    bash -c '
      unset GITHUB_WORKSPACE
      . "$1" 2>/dev/null || exit 90
      verify_gate "$2" 2>"$3"
      printf "%s" "$SH_VERIFY_UNRESOLVED" > "$4"
      printf "%s" "$SH_VERIFY_FAILED"
    ' _ "$V" "$base" "$FIX/stderr.txt" "$FIX/unresolved.txt"
  )"
  GATE_RC=$?
  OUT="$(cat "$FIX/stderr.txt" 2>/dev/null)"
  UNRESOLVED="$(cat "$FIX/unresolved.txt" 2>/dev/null)"
}

case_banner "no verify: key — the pre-existing consumer"
printf 'version: 1\n' > "$FIX/none.yml"
gate "$FIX/none.yml"
[ "$GATE_RC" -eq 0 ] && ok "returns 0" || bad "returned $GATE_RC"
case "$OUT" in '') ok "logs nothing — the gate is absent, not passing" ;; *) bad "logged: $OUT" ;; esac
case "$(wc -l < "$ARGV" | tr -d ' ')" in 0) ok "never invokes claude" ;; *) bad "invoked claude with no gate configured" ;; esac

case_banner "green gate"
printf 'version: 1\nverify: "true"\n' > "$FIX/green.yml"
gate "$FIX/green.yml"
[ "$GATE_RC" -eq 0 ] && ok "returns 0" || bad "returned $GATE_RC"
case "$OUT" in *"verify: green"*) ok "logs green" ;; *) bad "no green log: $OUT" ;; esac
case "$FAILED" in '') ok "SH_VERIFY_FAILED is empty, so the PR body stays clean" ;; *) bad "reported a failure on a green gate: $FAILED" ;; esac
case "$OUT" in *diagnose*) bad "diagnosed an environment that worked: $OUT" ;; *) ok "no diagnostic — there is nothing to explain" ;; esac
case "$(wc -l < "$ARGV" | tr -d ' ')" in 0) ok "never re-enters" ;; *) bad "re-entered on a green gate" ;; esac

case_banner "permanently red gate, default 2 re-entries"
printf 'version: 1\nverify: "echo boom-marker; exit 3"\n' > "$FIX/red.yml"
gate "$FIX/red.yml"
[ "$GATE_RC" -eq 0 ] && ok "STILL returns 0 — a red gate never stalls the issue" || bad "returned $GATE_RC: a lint error would now strand the work"
case "$(wc -l < "$ARGV" | tr -d ' ')" in
  2) ok "re-entered exactly twice, then stopped" ;;
  *) bad "re-entered $(wc -l < "$ARGV" | tr -d ' ') times, expected 2" ;;
esac
if grep -q -- '--continue' "$ARGV"; then ok "re-entry resumes the session (--continue)"; else bad "re-entry started a cold session: $(cat "$ARGV")"; fi
if grep -q -- '--max-turns 30' "$ARGV"; then ok "re-entry uses the verify_reentry turn cap, not implement's"; else bad "wrong turn cap: $(cat "$ARGV")"; fi
case "$FAILED" in *boom-marker*) ok "SH_VERIFY_FAILED carries the command output" ;; *) bad "no output captured: $FAILED" ;; esac
case "$OUT" in *"CI is the backstop"*) ok "says plainly that it is pushing anyway" ;; *) bad "no push-anyway log: $OUT" ;; esac
# A gate that RAN and failed is the agent's problem, not the environment's — a
# PATH dump here would send the reader looking in the wrong place.
case "$OUT" in *diagnose*) bad "blamed the environment for a gate that ran: $OUT" ;; *) ok "no diagnostic on a genuinely red gate" ;; esac

case_banner "verify_reentries: 0 — gate runs, never re-enters"
printf 'version: 1\nverify: "exit 1"\nverify_reentries: 0\n' > "$FIX/zero.yml"
gate "$FIX/zero.yml"
[ "$GATE_RC" -eq 0 ] && ok "returns 0" || bad "returned $GATE_RC"
case "$(wc -l < "$ARGV" | tr -d ' ')" in 0) ok "no re-entry" ;; *) bad "re-entered despite verify_reentries: 0" ;; esac
# A command that exits non-zero with NO output is the case that would leave an
# empty report and a pull request indistinguishable from a green one.
case "$FAILED" in
  '')          bad "still-red gate reported nothing to the PR body" ;;
  *'exited 1'*) ok "reports the exit status even when the command printed nothing" ;;
  *)           bad "report does not carry the exit status: $FAILED" ;;
esac
case "$FAILED" in *'(no output)'*) ok "says explicitly that there was no output" ;; *) bad "silent failure not labelled: $FAILED" ;; esac

case_banner "red then green — the case the gate exists for"
# Fails while a marker is absent; the stub claude creates it, standing in for an
# agent that fixed the cause.
cat > "$FIX/flaky.yml" <<EOF
version: 1
verify: "test -f $FIX/fixed"
EOF
cat > "$FIX/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${SH_TEST_CLAUDE_ARGV:?}"
cat > /dev/null
touch "$FIX/fixed"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":2}'
EOF
chmod +x "$FIX/bin/claude"
rm -f "$FIX/fixed"
gate "$FIX/flaky.yml"
[ "$GATE_RC" -eq 0 ] && ok "returns 0" || bad "returned $GATE_RC"
case "$(wc -l < "$ARGV" | tr -d ' ')" in 1) ok "one re-entry was enough" ;; *) bad "expected 1 re-entry, got $(wc -l < "$ARGV" | tr -d ' ')" ;; esac
case "$OUT" in *"green after 1 re-entry"*) ok "logs that the repair worked" ;; *) bad "no recovery log: $OUT" ;; esac
case "$FAILED" in '') ok "nothing reported to the PR body — it ended green" ;; *) bad "reported a failure after recovering: $FAILED" ;; esac

case_banner "tokens are withheld from the verify command"
# The command prints what it can see; the gate must have unset all three.
cat > "$FIX/tok.yml" <<'EOF'
version: 1
verify: "echo GH=[$GH_TOKEN] OA=[$CLAUDE_CODE_OAUTH_TOKEN] GT=[$GITHUB_TOKEN]; exit 1"
verify_reentries: 0
EOF
ARGV="$FIX/argv.tok"; : > "$ARGV"
FAILED="$(
  PATH="$FIX/bin:$PATH" SH_TEST_CLAUDE_ARGV="$ARGV" SMALLHOURS_CONFIG="$FIX/tok.yml" \
  CLAUDE_CODE_OAUTH_TOKEN=oauth-secret GH_TOKEN=gh-secret GITHUB_TOKEN=gt-secret \
  SMALLHOURS_JOB_CAP_MINUTES= \
  bash -c '
    unset GITHUB_WORKSPACE
    . "$1" 2>/dev/null || exit 90
    verify_gate "$2" 2>/dev/null
    printf "%s" "$SH_VERIFY_FAILED"
  ' _ "$V" "$FIX/tok-result.json"
)"
case "$FAILED" in
  *secret*) bad "a token reached the verify command: $FAILED" ;;
  *'GH=[] OA=[] GT=[]'*) ok "all three tokens unset for the command" ;;
  *) bad "unexpected verify output: $FAILED" ;;
esac

case_banner "the gate could not run — the command's own executable is missing"
# mediamtx-connect#300: `pnpm` was not on the gate's PATH, and re-entry spent 31
# turns and $2.22 rewriting code that was already correct. The agent cannot
# change the shell the gate runs in, so re-entry can never succeed here.
printf 'version: 1\nverify: "sh-no-such-tool-xyz --check"\n' > "$FIX/unres.yml"
# An empty HOME, so the on-disk probe searches only small system roots and
# reaches a verdict rather than timing out on whatever this machine keeps in
# ~/.npm — the assertion below is about which verdict, not about how fast the
# developer's package cache is.
mkdir -p "$FIX/home-clean"
gate "$FIX/unres.yml" "$FIX/home-clean"
[ "$GATE_RC" -eq 0 ] && ok "returns 0 — an unrunnable gate never stalls the issue" || bad "returned $GATE_RC"
case "$(wc -l < "$ARGV" | tr -d ' ')" in
  0) ok "never re-enters — no Claude stage is spent on an environment fault" ;;
  *) bad "re-entered $(wc -l < "$ARGV" | tr -d ' ') times on an unresolvable command" ;;
esac
case "$UNRESOLVED" in
  sh-no-such-tool-xyz) ok "SH_VERIFY_UNRESOLVED names the missing executable" ;;
  '') bad "gate did not classify a missing first token as could-not-run" ;;
  *) bad "named the wrong executable: $UNRESOLVED" ;;
esac
case "$OUT" in *"could not run"*) ok "log says the gate could not run, not that the code failed" ;; *) bad "no could-not-run log: $OUT" ;; esac
case "$FAILED" in *'exited 127'*) ok "report still carries the command and its exit status" ;; *) bad "no report body: $FAILED" ;; esac
case_banner "diagnosing never aborts the run"
# implement.sh runs `set -euo pipefail` and sources this file, so a probe that
# exits non-zero — a killed `find`, an `ls` of a directory that is not there —
# would kill the stage at the one moment the branch still has to be pushed and
# the PR still has to explain itself. The failure would look like a crash, not a
# missing log line, which is why it is worth a case of its own.
printf 'version: 1\nverify: "sh-no-such-tool-xyz"\nverify_reentries: 0\n' > "$FIX/strict.yml"
STRICT_OUT="$(
  PATH="$FIX/bin:$PATH" SH_TEST_CLAUDE_ARGV="$FIX/argv.strict" \
  SMALLHOURS_CONFIG="$FIX/strict.yml" CLAUDE_CODE_OAUTH_TOKEN=stub \
  SMALLHOURS_JOB_CAP_MINUTES= HOME="$FIX/home-planted" \
  bash -c '
    set -euo pipefail
    unset GITHUB_WORKSPACE
    . "$1" 2>/dev/null || exit 90
    verify_gate "$2" 2>/dev/null
    printf "SURVIVED"
  ' _ "$V" "$FIX/strict-result.json" 2>/dev/null
)"
case "$STRICT_OUT" in
  SURVIVED) ok "the caller keeps running under set -euo pipefail" ;;
  *) bad "the diagnostic aborted a strict-mode caller — the push would never happen" ;;
esac

case_banner "a 127 from INSIDE the command is still the agent's to fix"
# The consumer's own script shells out to a tool the agent should have
# installed. The gate started, so re-entry can succeed and must happen —
# distinguishing this from the case above is the whole point of the check.
cat > "$FIX/bin/wrapper-tool" <<'EOF'
#!/usr/bin/env bash
nested-no-such-tool-xyz
EOF
chmod +x "$FIX/bin/wrapper-tool"
cat > "$FIX/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SH_TEST_CLAUDE_ARGV:?}"
cat > /dev/null
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":2}'
EOF
chmod +x "$FIX/bin/claude"
printf 'version: 1\nverify: "wrapper-tool"\nverify_reentries: 1\n' > "$FIX/nested.yml"
gate "$FIX/nested.yml"
case "$UNRESOLVED" in '') ok "not classified as could-not-run — the gate did start" ;; *) bad "wrongly blamed the environment for $UNRESOLVED" ;; esac
case "$(wc -l < "$ARGV" | tr -d ' ')" in 1) ok "re-enters so the agent can install what its own command needs" ;; *) bad "expected 1 re-entry, got $(wc -l < "$ARGV" | tr -d ' ')" ;; esac

case_banner "the tool directory the agent may write is on the gate's PATH (ADR 0014)"
# The mechanism that replaces "your verify command must resolve its own entry
# point": everything else on PATH is unwritable inside the sandbox, so this is
# the only place an agent-installed tool can outlive its own process.
# PREFIX is the single source of truth — BIN is derived from it, so the sandbox
# path the agent may write and the PATH entry the gate adds can never diverge.
export SMALLHOURS_TOOL_PREFIX="$FIX/tools"
SMALLHOURS_TOOL_BIN="$SMALLHOURS_TOOL_PREFIX/bin"
mkdir -p "$SMALLHOURS_TOOL_BIN"
printf '#!/bin/sh\necho agent-installed-tool ran\n' > "$SMALLHOURS_TOOL_BIN/agent-tool"
chmod +x "$SMALLHOURS_TOOL_BIN/agent-tool"
printf 'version: 1\nverify: "agent-tool"\nverify_reentries: 0\n' > "$FIX/toolbin.yml"
gate "$FIX/toolbin.yml" "$FIX/home-clean"
case "$FAILED" in '') ok "a tool installed in the tool directory resolves" ;; *) bad "gate could not see it: $FAILED" ;; esac
case "$OUT" in *"tools the agent installed: "*agent-tool*) ok "logs what the agent installed — the only review surface it has" ;; *) bad "no tool listing in the log: $OUT" ;; esac

# The property `corepack pnpm run verify` lacked, and the one no fixture caught
# until a consumer paid for it: a command that re-invokes a tool BY NAME must
# resolve it too. PATH has to be exported, not merely resolved once.
printf '#!/bin/sh\nagent-tool\n' > "$SMALLHOURS_TOOL_BIN/wrapper-tool-xyz"
chmod +x "$SMALLHOURS_TOOL_BIN/wrapper-tool-xyz"
printf 'version: 1\nverify: "wrapper-tool-xyz"\nverify_reentries: 0\n' > "$FIX/nested-tool.yml"
gate "$FIX/nested-tool.yml" "$FIX/home-clean"
case "$FAILED" in '') ok "a script in it that re-invokes another tool by name resolves too" ;; *) bad "children do not inherit the tool directory: $FAILED" ;; esac
unset SMALLHOURS_TOOL_PREFIX

case_banner "history expansion never touches the consumer's command"
# An interactive shell expands `!` in what it parses. A verify command
# containing one would be mangled before it ran.
printf 'version: 1\nverify: "test ! -f /nonexistent-xyz && echo bang-ok; exit 1"\nverify_reentries: 0\n' > "$FIX/bang.yml"
gate "$FIX/bang.yml"
case "$FAILED" in *bang-ok*) ok "a '!' in the command survives verbatim" ;; *) bad "history expansion mangled the command: $FAILED" ;; esac

echo
echo "test-verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
