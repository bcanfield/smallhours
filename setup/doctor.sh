#!/usr/bin/env bash
# doctor.sh — drift check for an onboarded consumer repo.
#
# STUB (Milestone 1). Implemented in Milestone 4. Planned behaviour
# (docs/IMPLEMENTATION-PLAN.md M4): re-check everything setup-repo.sh
# established — Fixer App install, stub present + version-current, default
# config, label vocabulary, branch protection, push protection, CI workflow —
# plus stub version drift. Exits nonzero on any drift so it can gate a
# scheduled toolkit-repo audit across all onboarded repos.
set -euo pipefail

usage() { echo "usage: $0 <owner/repo>" >&2; }

main() {
  if [ "$#" -ne 1 ]; then usage; exit 64; fi
  echo "doctor.sh is not yet implemented (Milestone 4)." >&2
  exit 2
}

main "$@"
