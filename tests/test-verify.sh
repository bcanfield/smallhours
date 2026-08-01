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
# ADR 0012 decision 2. A tool that is nowhere on this machine could not have been
# run by ANY shell, so nothing here is ours to fix — the log has to say that,
# because the message is identical to the case below where it is.
case "$OUT" in *"diagnose:   PATH ="*) ok "diagnostic records the gate's own PATH" ;; *) bad "no PATH probe: $OUT" ;; esac
case "$OUT" in
  *"nothing on this runner provides it"*) ok "says the toolchain never existed here, so no shell could have run it" ;;
  *"EXISTS but no shell"*) bad "claimed the tool exists when nothing was planted: $OUT" ;;
  *) bad "no verdict line in the diagnostic: $OUT" ;;
esac

case_banner "the diagnostic tells 'exists but unreachable' from 'never existed'"
# The distinction the whole of #29 turned on, and the one the two mechanisms
# cannot be told apart by: both print the same `command not found`. A tool on
# disk but on no PATH is a gate we COULD have run — ADR 0012's payoff trigger.
mkdir -p "$FIX/home-planted/.local/share/probe-bin"
printf '#!/bin/sh\nexit 0\n' > "$FIX/home-planted/.local/share/probe-bin/sh-planted-tool-xyz"
chmod +x "$FIX/home-planted/.local/share/probe-bin/sh-planted-tool-xyz"
printf 'version: 1\nverify: "sh-planted-tool-xyz"\nverify_reentries: 0\n' > "$FIX/planted.yml"
gate "$FIX/planted.yml" "$FIX/home-planted"
case "$UNRESOLVED" in sh-planted-tool-xyz) ok "still classified as could-not-run" ;; *) bad "not classified: '$UNRESOLVED'" ;; esac
case "$OUT" in
  *"on disk ("*"$FIX/home-planted/.local/share/probe-bin/sh-planted-tool-xyz"*)
    ok "names where the tool actually is, and how long looking took" ;;
  *) bad "the on-disk probe did not find a planted tool: $OUT" ;;
esac
case "$OUT" in
  *"EXISTS but no shell"*) ok "verdict says the gate could have run this — the case that is ours" ;;
  *) bad "wrong verdict for a tool that is on disk: $OUT" ;;
esac
case "$(wc -l < "$ARGV" | tr -d ' ')" in 0) ok "diagnosing costs no Claude re-entry" ;; *) bad "re-entered while diagnosing" ;; esac

case_banner "a hit inside a launcher's cache is the contract case, not ours"
# The exact path mediamtx-connect#306 produced: `npx pnpm` downloads pnpm into
# ~/.npm/_npx/<hash>/node_modules/.bin and runs it from there. The file exists,
# but that directory was on nobody's PATH — not the gate's, not the agent's.
# Reading it as "we failed to reach your toolchain" would fire ADR 0012's payoff
# trigger for every npx-based consumer, which is most of them.
mkdir -p "$FIX/home-npx/.npm/_npx/acaf29b40d536b0e/node_modules/.bin"
printf '#!/bin/sh\nexit 0\n' > "$FIX/home-npx/.npm/_npx/acaf29b40d536b0e/node_modules/.bin/sh-planted-tool-xyz"
chmod +x "$FIX/home-npx/.npm/_npx/acaf29b40d536b0e/node_modules/.bin/sh-planted-tool-xyz"
gate "$FIX/planted.yml" "$FIX/home-npx"
case "$OUT" in
  *"on disk ("*"_npx/acaf29b40d536b0e"*) ok "still reports where it found it" ;;
  *) bad "did not report the cached copy: $OUT" ;;
esac
case "$OUT" in
  *"found only inside a package cache"*) ok "verdict names it as the per-invocation case" ;;
  *"EXISTS but no shell"*) bad "blamed the gate for a file in an npx cache: $OUT" ;;
  *) bad "no verdict line: $OUT" ;;
esac

case_banner "a search that ran out of time says so instead of claiming absence"
# The gate-environment job caught this on the probe's first run: a depth-6 walk
# of /usr/local did not finish in 8s on a BARE ubuntu-24.04, so the probe
# reported "not found" having proved nothing — and the verdict line went on to
# tell the consumer the failure was theirs. A timeout and an absence must never
# read the same, because only one of them is evidence.
export SH_VERIFY_PROBE_SECONDS=0
gate "$FIX/unres.yml" "$FIX/home-planted"
unset SH_VERIFY_PROBE_SECONDS
case "$OUT" in
  *"on disk: INCONCLUSIVE"*) ok "says the search was cut off, not that the tool is absent" ;;
  *"not found under"*) bad "a cut-off search claimed the tool does not exist: $OUT" ;;
  *) bad "no on-disk line at all: $OUT" ;;
esac
case "$OUT" in
  *"could not tell whether it exists here"*) ok "verdict withholds judgement rather than blaming the consumer" ;;
  *"nothing on this runner provides it"*) bad "drew the confident verdict from an unfinished search: $OUT" ;;
  *) bad "no verdict line: $OUT" ;;
esac
case "$UNRESOLVED" in sh-no-such-tool-xyz) ok "classification is unaffected by the probe's outcome" ;; *) bad "classification changed: '$UNRESOLVED'" ;; esac

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

case_banner "a distro's command-not-found handler does not defeat the classification"
# `-i` pulls in /etc/bash.bashrc, where Debian and Ubuntu define
# command_not_found_handle. Its message is the distro's, not bash's, so the
# gate stops recognising the one thing it has to parse. Caught on a real
# ubuntu-24.04 runner, where the gate re-entered on an unresolvable command and
# the run died on the missing OAuth token.
mkdir -p "$FIX/home-cnf"
cat > "$FIX/home-cnf/.bashrc" <<'EOF'
command_not_found_handle() {
  printf "Command '%s' not found, but can be installed with:\n" "$1" >&2
  printf "apt install something\n" >&2
  return 127
}
EOF
printf 'version: 1\nverify: "sh-no-such-tool-xyz"\nverify_reentries: 2\n' > "$FIX/cnf.yml"
gate "$FIX/cnf.yml" "$FIX/home-cnf"
case "$UNRESOLVED" in
  sh-no-such-tool-xyz) ok "classified despite the distro handler" ;;
  *) bad "the distro's handler hid the missing command (UNRESOLVED='$UNRESOLVED')" ;;
esac
case "$(wc -l < "$ARGV" | tr -d ' ')" in 0) ok "still no re-entry" ;; *) bad "re-entered anyway" ;; esac

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

case_banner "a toolchain on PATH only via shell startup files resolves"
# The property #29 is about, stated without reference to any language: whatever
# the agent bootstrapped for itself must be visible to the gate. Three HOME
# arrangements, because no single bash invocation form covers all of them —
# ~/.bash_profile shadows ~/.profile, and a login shell never reads ~/.bashrc.
mkdir -p "$FIX/tools"
printf '#!/bin/sh\nexit 0\n' > "$FIX/tools/rc-only-tool"; chmod +x "$FIX/tools/rc-only-tool"
printf 'version: 1\nverify: "rc-only-tool"\nverify_reentries: 0\n' > "$FIX/rc.yml"

# 1. Ubuntu's stock arrangement: ~/.profile sources ~/.bashrc.
mkdir -p "$FIX/home-profile"
printf 'if [ -n "$BASH_VERSION" ]; then [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"; fi\n' > "$FIX/home-profile/.profile"
printf 'case $- in *i*) ;; *) return;; esac\nexport PATH="%s:$PATH"\n' "$FIX/tools" > "$FIX/home-profile/.bashrc"
gate "$FIX/rc.yml" "$FIX/home-profile"
case "$FAILED" in '') ok "resolves via ~/.profile -> ~/.bashrc" ;; *) bad "gate could not see the tool: $FAILED" ;; esac

# 2. A ~/.bash_profile shadows ~/.profile, so the chain to ~/.bashrc is severed.
mkdir -p "$FIX/home-bashprofile"
printf '# does not source .bashrc\n' > "$FIX/home-bashprofile/.bash_profile"
printf 'case $- in *i*) ;; *) return;; esac\nexport PATH="%s:$PATH"\n' "$FIX/tools" > "$FIX/home-bashprofile/.bashrc"
gate "$FIX/rc.yml" "$FIX/home-bashprofile"
case "$FAILED" in '') ok "resolves via ~/.bashrc even when ~/.bash_profile shadows the chain" ;; *) bad "gate could not see the tool: $FAILED" ;; esac

# 3. Profile chain only, no ~/.bashrc at all.
mkdir -p "$FIX/home-loginonly"
printf 'export PATH="%s:$PATH"\n' "$FIX/tools" > "$FIX/home-loginonly/.bash_profile"
gate "$FIX/rc.yml" "$FIX/home-loginonly"
case "$FAILED" in '') ok "resolves via the login profile chain with no ~/.bashrc" ;; *) bad "gate could not see the tool: $FAILED" ;; esac

case_banner "the interactive shell's own noise stays out of the report"
printf 'version: 1\nverify: "echo real-output; exit 1"\nverify_reentries: 0\n' > "$FIX/noise.yml"
gate "$FIX/noise.yml"
case "$FAILED" in
  *"no job control"*|*"cannot set terminal process group"*)
    bad "bash's job-control preamble leaked into the PR body: $FAILED" ;;
  *logout*) bad "the login shell's exit chatter leaked into the PR body: $FAILED" ;;
  *real-output*) ok "reports the command's output and none of bash's startup chatter" ;;
  *) bad "lost the command output: $FAILED" ;;
esac
# The command's own output must survive even where it looks like shell noise —
# only the leading/trailing positions are ours to strip.
printf 'version: 1\nverify: "echo logout; echo tail-line; exit 1"\nverify_reentries: 0\n' > "$FIX/midnoise.yml"
gate "$FIX/midnoise.yml"
case "$FAILED" in *logout*tail-line*) ok "a 'logout' the command itself printed is kept" ;; *) bad "stripped the command's own output: $FAILED" ;; esac

case_banner "history expansion never touches the consumer's command"
# An interactive shell expands `!` in what it parses. A verify command
# containing one would be mangled before it ran.
printf 'version: 1\nverify: "test ! -f /nonexistent-xyz && echo bang-ok; exit 1"\nverify_reentries: 0\n' > "$FIX/bang.yml"
gate "$FIX/bang.yml"
case "$FAILED" in *bang-ok*) ok "a '!' in the command survives verbatim" ;; *) bad "history expansion mangled the command: $FAILED" ;; esac

echo
echo "test-verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
