#!/usr/bin/env bash
# run-all.sh — every test suite, one command. What CI runs, and what you run.
#
#   tests/run-all.sh
#
# Runs each tests/test-*.sh to completion and reports at the end, rather than
# stopping at the first red: when a change to lib/config.sh breaks four suites,
# seeing all four is what tells you it was the shared thing and not the one file
# you happened to be looking at.
#
# Pure logic only — no network, no gh auth, no sudo. Every suite stubs what it
# needs, so this is safe to run anywhere and there is nothing to clean up.
#
# Requires: bash, jq, yq (ADR 0004). Exits non-zero if any suite fails.
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for tool in jq yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "run-all: $tool not found on PATH — see versions.env" >&2
    exit 1
  }
done

passed=0
failed=0
failures=()

for suite in "$_dir"/test-*.sh; do
  name="$(basename "$suite")"
  echo "──────────────────────────────────────────────────────────────"
  echo "▶ $name"
  echo "──────────────────────────────────────────────────────────────"
  if bash "$suite"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    failures+=("$name")
  fi
  echo
done

echo "══════════════════════════════════════════════════════════════"
if [ "$failed" -eq 0 ]; then
  echo "run-all: $passed suite(s) passed"
  exit 0
fi

echo "run-all: $failed of $((passed + failed)) suite(s) FAILED"
for f in "${failures[@]}"; do echo "  ✗ $f"; done
exit 1
