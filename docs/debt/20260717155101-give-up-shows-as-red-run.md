---
id: 20260717155101
title: give-up-shows-as-red-run
principal: 1h
interest: every hand-off looks like a CI failure in the Actions tab
hotspot: .github/workflows/agent-loop.yml
business_capability: planning
payoff_trigger: Milestone 5 dogfooding — if red give-up runs cause confusion
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-17
---

implement.sh / address-review.sh exit non-zero on a legitimate give-up (Claude CLI failure -> issue routed to ready-for-human), which fails the workflow step and paints the agent-loop run red in the Actions tab even though the outcome is a clean, intended hand-off. Chosen for visibility "for now"; the alternative is to capture the give-up as a job output and end green with a summary. Also means report-usage is skipped on the give-up path (no PR/usage comment). Revisit during M5 dogfooding if the red runs read as errors.
