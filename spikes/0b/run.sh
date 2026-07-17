#!/usr/bin/env bash
# Drives spike 0b end to end: create a throwaway issue, fire the `labeled`
# trigger twice in quick succession, then read the verdict off the issue.
#
#   ./spikes/0b/run.sh [owner/repo]
#
# Requires: gh (authenticated), and both spike-0b workflows merged to the
# DEFAULT BRANCH — `issues` events only ever run default-branch workflows.

set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
LABEL="spike-concurrency"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "repo: $REPO"

gh label create "$LABEL" --repo "$REPO" --color FBCA04 \
  --description "Spike 0b trigger (throwaway)" 2>/dev/null \
  || echo "label $LABEL already exists"

issue_url=$(gh issue create --repo "$REPO" \
  --title "spike 0b — concurrency inside a called reusable workflow" \
  --body "Throwaway. Evidence trail below: serialized runs read START/END/START/END; parallel runs read START/START/END/END. Close when ADR 0002's fallback question is settled.")
issue=${issue_url##*/}
echo "issue: #$issue  ($issue_url)"

# Two `labeled` events as close together as the API allows. The remove in
# between is what makes the second add a real event rather than a no-op.
echo "firing labeled #1"
gh issue edit "$issue" --repo "$REPO" --add-label "$LABEL"
gh issue edit "$issue" --repo "$REPO" --remove-label "$LABEL"
echo "firing labeled #2"
gh issue edit "$issue" --repo "$REPO" --add-label "$LABEL"

echo
echo "Both events fired. Each run holds its group for 60s."
echo "Waiting 200s before reading the verdict..."
sleep 200

exec "$HERE/verdict.sh" "$issue" "$REPO"
