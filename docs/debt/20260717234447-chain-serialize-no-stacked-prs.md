---
id: 20260717234447
title: chain-serialize-no-stacked-prs
principal: unknown
interest: +1 review-cycle latency per chain link
hotspot: scripts/dispatch.sh
business_capability: dispatch
payoff_trigger: Phase 2 sweep (M7) lands, or deep ticket chains make review-cadence serialization painful
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-17
---

ADR 0006 makes the dispatcher edge-aware but deliberately excludes stacked PRs: a dependent ticket only starts after its blocker's PR is merged to main, so deep to-tickets chains serialize on maintainer review cadence. Companion sub-decisions (edge representation, unblock semantics, failure modes) are still being grilled and will be appended to ADR 0006.
