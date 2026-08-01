#!/usr/bin/env bash
# test-workflow-wiring.sh — structural assertions on the reusable workflow.
#
# Reader: anyone editing .github/workflows/agent-loop.yml. Trigger: every run of
# tests/run-all.sh.
#
# It earns its place because agent-loop.yml is `workflow_call`-only: it never
# fires on a push or a pull request, so nothing in this repo's own CI executes a
# single line of it. A wrong path in one of a dozen near-identical jobs is
# invisible until that job happens to run, on a consumer, against the floating
# `v1` tag. These are the invariants whose breakage would look like nothing at
# all until then.
#
# Run: tests/test-workflow-wiring.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$_dir/../.github/workflows/agent-loop.yml"

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

JSON="$(yq -o=json '.' "$WF")" || { echo "test-workflow-wiring: cannot parse $WF" >&2; exit 1; }

# job <TAB> step-index <TAB> kind, one line per interesting step.
steps() {
  jq -r '
    .jobs | to_entries[] | .key as $job |
    (.value.steps // []) | to_entries[] |
    .key as $i | .value as $s |
    ($s.run // "") as $run |
    ($s.uses // "") as $uses |
    [
      (if $uses | startswith("actions/checkout") then
         (if ($s["with"].path // "") == ".smallhours-toolkit" then "checkout_toolkit" else empty end)
       else empty end),
      (if $run | test("SH_TOOLKIT=.*GITHUB_ENV"; "s") then "move" else empty end),
      (if $run | test("\\$SH_TOOLKIT|\\$\\{SH_TOOLKIT") then "uses_toolkit" else empty end),
      (if $run | test("info/exclude") then "exclude_write" else empty end),
      (if $run | test("(^|[^-])\\.smallhours-toolkit/") then "workspace_path" else empty end),
      (if $uses | startswith("./") then "local_action" else empty end)
    ][] as $kind |
    [$job, ($i|tostring), $kind] | @tsv
  ' <<< "$JSON"
}

ALL="$(steps)"

case_banner "the toolkit never stays in the consumer worktree (ADR 0010)"

# A repo-wide lint or type-check run by the verify gate walks whatever is in the
# tree. Anything of ours that is still there fails on files that are not the
# consumer's — three mediamtx-connect agents each paid a re-entry to find this.
if grep -q $'\tworkspace_path$' <<< "$ALL"; then
  bad "a step still runs the toolkit from inside the workspace:"$'\n'"$(grep $'\tworkspace_path$' <<< "$ALL" | sed 's/^/    /')"
else
  ok "no step executes anything from .smallhours-toolkit/ in the workspace"
fi

# `.git/info/exclude` was how `git add -A` was kept off the checkout. Nothing
# outside git reads that file, which is precisely why it did not help — if a
# step starts writing it again, the checkout has moved back into the tree.
if grep -q $'\texclude_write$' <<< "$ALL"; then
  bad "a step writes .git/info/exclude — no tool outside git reads it (#31)"
else
  ok "nothing depends on .git/info/exclude"
fi

# `uses: ./…` resolves against $GITHUB_WORKSPACE and takes no expressions, so a
# local action reference cannot reach an out-of-workspace toolkit at all.
if grep -q $'\tlocal_action$' <<< "$ALL"; then
  bad "a local action path survives; it cannot resolve to the moved toolkit"
else
  ok "no local action paths"
fi

case_banner "every toolkit checkout is moved out before anything uses it"

jobs="$(cut -f1 <<< "$ALL" | sort -u)"
for job in $jobs; do
  job_steps="$(awk -F'\t' -v j="$job" '$1 == j' <<< "$ALL")"
  n_checkout="$(grep -c $'\tcheckout_toolkit$' <<< "$job_steps")"
  n_move="$(grep -c $'\tmove$' <<< "$job_steps")"
  [ "$n_checkout" -eq 0 ] && [ "$n_move" -eq 0 ] && continue

  if [ "$n_checkout" -ne "$n_move" ]; then
    bad "$job: $n_checkout toolkit checkout(s) but $n_move move step(s)"
    continue
  fi

  move_at="$(awk -F'\t' '$3 == "move" {print $2; exit}' <<< "$job_steps")"
  # $SH_TOOLKIT is published by the move step into $GITHUB_ENV, so a step that
  # reads it earlier expands to an empty prefix and silently runs the wrong
  # path — or, worse for the give-up paths, a path that happens to exist.
  early="$(awk -F'\t' -v m="$move_at" '$3 == "uses_toolkit" && ($2 + 0) < (m + 0) {print $2}' <<< "$job_steps")"
  if [ -n "$early" ]; then
    bad "$job: step(s) $(tr '\n' ' ' <<< "$early")use \$SH_TOOLKIT before the move step at $move_at"
  else
    ok "$job: toolkit moved at step $move_at, before every use"
  fi
done

case_banner "the consumer stub still matches the reusable workflow's secrets"
# The stub is what consumers copy; a secret required here and absent there fails
# at dispatch time on their repo, not ours.
required="$(jq -r '.on.workflow_call.secrets | to_entries[] | select(.value.required) | .key' <<< "$JSON" | sort)"
stub="$(yq -o=json '.' "$_dir/../stub/agent-loop.yml" | jq -r '.jobs[].secrets // {} | keys[]' 2>/dev/null | sort)"
if [ -z "$stub" ]; then
  # `secrets: inherit` forwards everything, which satisfies the contract too.
  if yq -r '.jobs[].secrets // ""' "$_dir/../stub/agent-loop.yml" | grep -q inherit; then
    ok "stub forwards secrets with \`inherit\`"
  else
    bad "stub forwards no secrets, but the workflow requires: $(tr '\n' ' ' <<< "$required")"
  fi
elif [ "$required" = "$stub" ]; then
  ok "stub forwards exactly the required secrets"
else
  bad "stub/workflow secret mismatch — required: $(tr '\n' ' ' <<< "$required") stub: $(tr '\n' ' ' <<< "$stub")"
fi

echo
echo "test-workflow-wiring: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
