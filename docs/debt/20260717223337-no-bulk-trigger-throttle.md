---
id: 20260717223337
title: no-bulk-trigger-throttle
principal: 3h
interest: one bulk label action = N parallel Claude runs + N PRs; large token/PR blast radius
hotspot: .github/workflows/agent-loop.yml
business_capability: release
payoff_trigger: BLOCKER — before re-enabling the loop on any repo
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-17
---

Discovered in M5 dogfooding: applying ready-for-agent to ~17 issues at once fired ~17 parallel implement jobs (per-issue concurrency isolates issues but doesn't cap the total). No global throttle means a bulk label action (intentional or fat-fingered) unleashes N Claude runs + N PRs + N* token spend. The design's only guard is the operational "only label issues you understand." Fix before re-enabling: a workflow-level concurrency group that serializes implement (slow drip), and/or a per-run cap. Cleanup of the incident: 31 issues parked to temp-agent-working, 2 agent branches deleted.
