#!/usr/bin/env bash
# test-implement-giveup.sh — what implement.sh LEAVES BEHIND when it gives up,
# driven end to end against a local bare remote with stubbed `claude` and `gh`.
# No network, no tokens, no spend.
#
# Reader: anyone changing which give-ups preserve partial work, or the
# preservation path itself (_capture_work / claude_was_cut_off).
#
# This exists because the untested seam is the one that cost money. ADR 0007
# shipped preservation keyed on `error_timeout` alone; the unit tests all
# passed, because the predicate was inline in implement.sh and nothing
# exercised the path. The first real run afterwards — mediamtx-connect#291 —
# exhausted its TURN cap instead (101/100, 18 minutes, $6.20) and fifteen files
# of finished work died with the runner. The properties below are cheap to
# assert and were expensive to learn:
#
#   1. BOTH allowance give-ups preserve. They are the same event with different
#      meters, and which one bites depends on the work, not the ticket.
#   2. Nothing else preserves. A deliberate stop is not a cut-off.
#   3. A cut-off with an empty tree pushes NOTHING — no empty ref litter.
#   4. A preserved run opens NO pull request. This is load-bearing: a draft PR
#      starts consumer CI, and red CI on an `agent` PR feeds the auto-fix loop,
#      which would spend attempt_cap runs greening half-implemented work.
#   5. The handback names the branch, or a human cannot find what survived.
#
# Run: tests/test-implement-giveup.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL="$_dir/../scripts/implement.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-giveup.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

command -v git >/dev/null || { echo "test-implement-giveup: git unavailable — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "test-implement-giveup: jq unavailable — skipping";  exit 0; }

# ── Fixture: a bare "origin" plus a working clone on main ────────────────────
git init -q --bare "$FIX/remote.git"
git init -q "$FIX/repo"
git -C "$FIX/repo" config user.email t@example.com
git -C "$FIX/repo" config user.name  tester
printf '# Features\n' > "$FIX/repo/FEATURES.md"
git -C "$FIX/repo" add -A
git -C "$FIX/repo" commit -qm base
git -C "$FIX/repo" branch -M main
git -C "$FIX/repo" remote add origin "$FIX/remote.git"
git -C "$FIX/repo" push -q -u origin main

# ── Stub gh: log every call; answer only what implement.sh actually asks ─────
mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "issue view")
    printf '%s\n' '{"number":901,"title":"A ticket","body":"Do the thing."}' ;;
  "issue comment")
    while [ $# -gt 0 ]; do [ "$1" = "--body" ] && printf '%s' "$2" > "$COMMENT_FILE"; shift; done ;;
  "repo view") printf 'main\n' ;;
  *) printf '\n' ;;
esac
exit 0
STUB
chmod +x "$FIX/bin/gh"

export PATH="$FIX/bin:$PATH"
export GITHUB_REPOSITORY=acme/demo GH_TOKEN=stub CLAUDE_CODE_OAUTH_TOKEN=stub
export SMALLHOURS_CONFIG="$FIX/no-such-config.yml"
export GH_LOG="$FIX/gh.log" COMMENT_FILE="$FIX/comment.txt" REPO_DIR="$FIX/repo"

# Drive one give-up. Writes a `claude` stub that dirties the tree (or doesn't)
# and exits with the given terminal subtype, then runs the REAL implement.sh.
run_giveup() { # subtype dirty|clean issue
  export SMALLHOURS_RESULT_JSON="$FIX/result-$3.json"
  cat > "$FIX/bin/claude" <<STUB
#!/usr/bin/env bash
cd "\$REPO_DIR"
[ "$2" = "dirty" ] && printf 'partial\n' > "work-$3.txt"
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"work-$3.txt"}}]}}'
echo '{"type":"result","subtype":"$1","is_error":true,"num_turns":42,"duration_ms":60000}'
exit 1
STUB
  chmod +x "$FIX/bin/claude"
  : > "$GH_LOG"; : > "$COMMENT_FILE"
  git -C "$FIX/repo" checkout -q main 2>/dev/null
  git -C "$FIX/repo" clean -qfd
  ( cd "$FIX/repo" && "$IMPL" "$3" >/dev/null 2>&1 )
  RC=$?
}
pushed() { git -C "$FIX/remote.git" show-ref --verify --quiet "refs/heads/agent/issue-$1"; }

case_banner "an allowance give-up preserves partial work on a branch"
for st in error_max_turns error_timeout; do
  case "$st" in error_max_turns) n=901 ;; *) n=902 ;; esac
  run_giveup "$st" dirty "$n"
  [ "$RC" -eq 4 ] && ok "$st exits 4 (give-up)" || bad "$st exit was $RC, want 4"
  if pushed "$n"; then
    ok "$st pushed agent/issue-$n"
    git -C "$FIX/remote.git" show --stat --format= "agent/issue-$n" | grep -q "work-$n.txt" \
      && ok "$st branch carries the agent's actual work" || bad "$st branch is missing the work"
  else
    bad "$st left NO branch — this is the mediamtx-connect#291 regression"
  fi
  grep -q "agent/issue-$n" "$COMMENT_FILE" \
    && ok "$st handback names the branch" || bad "$st handback does not name the branch"
  grep -q "^gh pr create" "$GH_LOG" \
    && bad "$st opened a PR — auto-fix would then chase half-implemented work" \
    || ok "$st opened NO pull request"
done

case_banner "a deliberate stop is not a cut-off and preserves nothing"
run_giveup error_during_execution dirty 903
pushed 903 && bad "error_during_execution pushed a branch" || ok "error_during_execution left no branch"
run_giveup some_future_subtype dirty 904
pushed 904 && bad "an unknown subtype pushed a branch" || ok "unknown subtype left no branch (fails closed)"

case_banner "a cut-off that produced nothing leaves no empty ref"
run_giveup error_max_turns clean 905
pushed 905 && bad "empty tree still created agent/issue-905" || ok "empty tree pushed nothing"
[ "$RC" -eq 4 ] && ok "still exits 4 with nothing to save" || bad "empty-tree exit was $RC, want 4"

echo
echo "test-implement-giveup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
