---
id: 20260724235215
title: autofix-burns-attempt-on-flaky-ci
principal: 1d
interest: a flake converts into an early hand-off instead of a free retry
hotspot: scripts/auto-fix.sh
business_capability: release
payoff_trigger: M6 dogfooding shows flake-driven give-ups on mediamtx-connect
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-24
---

A red CI run caused by a flaky or unrelated test consumes an auto-fix attempt (M5.5 saw exactly this live: an unrelated E2E flake on mediamtx-connect). The prompt tells the agent to make NO changes when the failure looks unrelated, and auto-fix.sh treats a no-diff run as a give-up — so a flake becomes an early hand-off to a human rather than a wasted Claude fix, but there is no "just re-run CI" primitive that would let the system retry a suspected flake without spending an attempt or a human. Green still resets the counter, so the cap can never fire from flakes separated by successes.
