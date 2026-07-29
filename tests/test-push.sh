#!/usr/bin/env bash
# test-push.sh — the failure contract of sh_push (lib/common.sh) against a real
# git remote. No network: a local bare repo stands in, and a pre-receive hook
# supplies the rejection.
#
# Reader: anyone changing sh_push or a stage's push handling. This exists
# because the untested branch is the one that mattered — a bare `git push`
# under `set -e` stranded mediamtx-connect#214 in agent-working on a dead
# branch with no comment and no state change (smallhours#24). Two properties
# hold that together and are both easy to break silently: the rejection text
# must arrive on STDOUT (the give-up comment quotes it) while still reaching
# the job log, and a clean push must stay silent on stdout so no caller
# mistakes success for a reason string.
# Run: tests/test-push.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$_dir/../scripts/lib/common.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-push.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

command -v git >/dev/null || { echo "test-push: git not available — skipping"; exit 0; }

# A bare remote plus a working clone with one commit on a branch to push.
git init --quiet --bare "$FIX/remote.git"
git init --quiet "$FIX/work"
(
  cd "$FIX/work"
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$FIX/remote.git"
  echo hello > file.txt
  git add file.txt
  git commit --quiet -m "initial"
  git checkout --quiet -b agent/issue-214
) >/dev/null 2>&1

# Reject exactly the way GitHub does for a workflow-file push without the
# `workflows` permission: non-zero exit plus an explanatory remote message.
cat > "$FIX/remote.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "refusing to allow a GitHub App to create or update workflow \`.github/workflows/ci.yml\` without \`workflows\` permission" >&2
exit 1
EOF
chmod +x "$FIX/remote.git/hooks/pre-receive"

# Run sh_push inside the clone, capturing its stdout, stderr and status apart.
push() { # git-push-args…
  ( cd "$FIX/work"
    . "$COMMON" 2>/dev/null || exit 90
    sh_push "$@" ) >"$FIX/out" 2>"$FIX/err"
}

case_banner "a rejected push reports the reason instead of dying silently"
push --set-upstream origin agent/issue-214
rc=$?
[ "$rc" -ne 0 ] && ok "returns non-zero so the caller can route it to a give-up" \
                || bad "returned 0 on a rejected push — the caller would proceed as if it landed"
grep -q "without .workflows. permission" "$FIX/out" \
  && ok "remote's rejection text lands on stdout (the give-up comment quotes it)" \
  || bad "stdout carried no reason: $(cat "$FIX/out")"
grep -q "without .workflows. permission" "$FIX/err" \
  && ok "same text still reaches stderr (the job log keeps its copy)" \
  || bad "stderr lost git's output: $(cat "$FIX/err")"

case_banner "a clean push is silent on stdout"
rm -f "$FIX/remote.git/hooks/pre-receive"
push --set-upstream origin agent/issue-214
rc=$?
[ "$rc" -eq 0 ] && ok "returns 0" || bad "clean push returned $rc: $(cat "$FIX/err")"
[ ! -s "$FIX/out" ] \
  && ok "no stdout, so success can never be read as a rejection reason" \
  || bad "clean push wrote to stdout: $(cat "$FIX/out")"
git --git-dir="$FIX/remote.git" rev-parse --verify --quiet agent/issue-214 >/dev/null \
  && ok "branch actually reached the remote" || bad "branch missing from the remote"

case_banner "the rejection is capped, so a chatty hook cannot blow up the comment"
cat > "$FIX/remote.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
i=0; while [ $i -lt 5000 ]; do echo "noisy hook line $i" >&2; i=$((i+1)); done
exit 1
EOF
chmod +x "$FIX/remote.git/hooks/pre-receive"
(cd "$FIX/work"; echo more >> file.txt; git commit --quiet -am "second") >/dev/null 2>&1
push origin agent/issue-214
[ "$(wc -c < "$FIX/out")" -le 2100 ] \
  && ok "stdout tail stays within the documented cap" \
  || bad "uncapped rejection text: $(wc -c < "$FIX/out") bytes"

echo
echo "test-push: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
