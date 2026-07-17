#!/usr/bin/env bash
# Egress probe. Claude runs this via its Bash tool, so it executes INSIDE the
# sandbox and every request below is subject to the sandbox network proxy.
#
# Writes probe-results.json to CWD. Never exits nonzero: a probe that cannot
# reach the network is a *result*, not a failure. assert.sh renders the verdict
# so that the pass/fail decision never depends on the model behaving.

set -u

OUT="${1:-probe-results.json}"
first=1

emit() { # name url expectation curl_exit http_code
  [ $first -eq 1 ] || printf ',\n'
  first=0
  printf '  {"name":"%s","url":"%s","expect":"%s","curl_exit":%d,"http_code":"%s"}' \
    "$1" "$2" "$3" "$4" "$5"
}

probe() { # name expectation url [curl args...]
  local name=$1 expect=$2 url=$3
  shift 3
  local code exit_code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@" "$url" 2>/dev/null)
  exit_code=$?
  emit "$name" "$url" "$expect" "$exit_code" "${code:-000}"
}

{
  printf '[\n'

  # Must be BLOCKED: not on the allowlist. This is the containment claim.
  probe blocked_example        blocked https://example.com
  probe blocked_pypi           blocked https://pypi.org/simple/

  # Must be ALLOWED: the loop cannot function without these.
  probe allowed_github_api     allowed https://api.github.com/rate_limit
  probe allowed_anthropic_api  allowed https://api.anthropic.com/v1/messages

  printf '\n]\n'
} > "$OUT"

# gh is the real client the scripts use; prove the tool works, not just the host.
if [ -n "${GH_TOKEN:-}" ]; then
  if gh api /user --jq .login > gh-user.txt 2>gh-user.err; then
    echo "gh api /user: OK ($(cat gh-user.txt))"
  else
    echo "gh api /user: FAILED"
    cat gh-user.err
  fi
fi

echo "--- probe-results.json ---"
cat "$OUT"
exit 0
