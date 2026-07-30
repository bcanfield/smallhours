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
gate() { # config-file
  local cfg="$1"
  ARGV="$FIX/argv.$RANDOM"; : > "$ARGV"
  local base="$FIX/result.$RANDOM.json"
  FAILED="$(
    PATH="$FIX/bin:$PATH" \
    SH_TEST_CLAUDE_ARGV="$ARGV" \
    SMALLHOURS_CONFIG="$cfg" \
    CLAUDE_CODE_OAUTH_TOKEN=stub \
    SMALLHOURS_JOB_CAP_MINUTES= \
    bash -c '
      unset GITHUB_WORKSPACE
      . "$1" 2>/dev/null || exit 90
      verify_gate "$2" 2>"$3"
      printf "%s" "$SH_VERIFY_FAILED"
    ' _ "$V" "$base" "$FIX/stderr.txt"
  )"
  GATE_RC=$?
  OUT="$(cat "$FIX/stderr.txt" 2>/dev/null)"
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

echo
echo "test-verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
