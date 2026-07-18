---
id: 20260717231228
title: rerun-reuses-agent-branch
principal: 2h
interest: re-labelling the same issue reuses agent/issue-N; a non-fast-forward push is rejected if the old branch survives
hotspot: scripts/implement.sh
business_capability: release
payoff_trigger: first retry / re-label of an already-attempted issue
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-17
---

implement.sh always builds agent/issue-N (attempt defaults to 1; the workflow passes no attempt), and resets it to origin/base + a new commit before `git push --set-upstream` (no force). If a prior attempt's branch still exists on the remote with divergent history, the push is rejected non-ff. DESIGN says retries should use fresh agent/issue-N-rK branches, but nothing yet increments the attempt on a re-label. Workaround today: delete the stale branch before re-running. Fix: track/increment attempt, or have open-pr/cancel delete the branch on give-up.
