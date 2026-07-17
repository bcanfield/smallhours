#!/usr/bin/env bash
# Reads spike 0b's verdict off the issue's comment log.
#
#   ./spikes/0b/verdict.sh <issue-number> [owner/repo]
#
# Exit 0 = serialized (concurrency works inside the called workflow — ADR 0002
# holds). Exit 1 = parallel, lost, or inconclusive (fall back to declaring
# concurrency in the stub, and accept the stub-fattening ADR 0002 anticipated).

set -uo pipefail

ISSUE="${1:?usage: verdict.sh <issue-number> [owner/repo]}"
REPO="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

markers=$(gh issue view "$ISSUE" --repo "$REPO" --json comments \
  --jq '.comments[].body' | grep -o 'SPIKE-0B run=[0-9]* event=[A-Z]*' || true)

if [ -z "$markers" ]; then
  echo "INCONCLUSIVE: no SPIKE-0B markers on issue #$ISSUE."
  echo "Neither run reached the marker step. Check that both workflows are on the"
  echo "default branch and that the caller's label filter matches."
  exit 1
fi

echo "Event log (chronological):"
echo "$markers" | sed 's/^/  /'
echo

runs=$(echo "$markers" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
starts=$(echo "$markers" | grep -c 'event=START' || true)
ends=$(echo "$markers" | grep -c 'event=END' || true)

echo "distinct runs: $runs   starts: $starts   ends: $ends"
echo

if [ "$starts" -lt 2 ]; then
  echo "INCONCLUSIVE: only $starts run(s) started — expected 2."
  echo "The second event was dropped rather than queued. That is its own finding:"
  echo "a dropped trigger means a re-labelled issue silently never gets worked."
  exit 1
fi

# The discriminator: walk the log and check whether a run ever STARTs while
# another is still open. That is exactly what the concurrency group forbids.
overlap=$(echo "$markers" | awk '
  $3 == "event=START" { if (open > 0) overlapped = 1; open++ }
  $3 == "event=END"   { open-- }
  END { print overlapped + 0 }
')

if [ "$overlap" -eq 0 ]; then
  echo "RESULT: SERIALIZED — no run started while another was open."
  echo "Job-level concurrency works inside a called reusable workflow."
  echo "ADR 0002 holds: the group stays behind the tag, stubs stay thin."
  exit 0
else
  echo "RESULT: PARALLEL — a run started while another was still open."
  echo "Job-level concurrency did NOT take effect from inside the called workflow."
  echo "Fall back to declaring concurrency in the stub (ADR 0002's accepted"
  echo "stub-fattening), and record it as an ADR 0002 addendum."
  exit 1
fi
