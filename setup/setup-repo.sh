#!/usr/bin/env bash
# setup-repo.sh — one-command consumer onboarding.
#
# STUB (Milestone 1). Implemented in Milestone 4. Planned behaviour
# (docs/IMPLEMENTATION-PLAN.md M4):
#   - install the Fixer GitHub App on <owner/repo>
#   - push the stub (stub/agent-loop.yml) + a default .smallhours.yml
#   - create the label vocabulary (state axis + category axis)
#   - set branch protection (require PR, 1 approval, CI check, up-to-date)
#   - enable secret-scanning push protection
#   - verify a CI workflow exists (the loop keys off it; warn if absent)
set -euo pipefail

usage() { echo "usage: $0 <owner/repo>" >&2; }

main() {
  if [ "$#" -ne 1 ]; then usage; exit 64; fi
  echo "setup-repo.sh is not yet implemented (Milestone 4)." >&2
  exit 2
}

main "$@"
