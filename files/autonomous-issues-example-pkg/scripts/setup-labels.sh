#!/usr/bin/env bash
# Create the label vocabulary in the current repo. Requires the `gh` CLI,
# authenticated (`gh auth login`). Idempotent: re-running just updates colors.
#
# Usage:  ./scripts/setup-labels.sh [owner/repo]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner')}"
echo "Creating labels in $REPO"

create() {
  local name="$1" color="$2" desc="$3"
  gh label create "$name" --color "$color" --description "$desc" -R "$REPO" 2>/dev/null \
    || gh label edit "$name" --color "$color" --description "$desc" -R "$REPO"
  echo "  ✓ $name"
}

create agent          5319e7 "Opt this issue in to autonomous implementation by Claude"
create in-progress    fbca04 "Claude has picked up the issue and is working"
create ci-failing     d73a4a "CI is red; auto-fix is attempting a repair"
create conflict       b60205 "Branch conflicts with base; needs resolution"
create needs-work     e99695 "Not yet green; still being worked by automation"
create ready-to-merge 0e8a16 "Green, conflict-free — awaiting human approval + merge"
create human-needed   0052cc "Automation gave up; needs a person"

echo "Done."
