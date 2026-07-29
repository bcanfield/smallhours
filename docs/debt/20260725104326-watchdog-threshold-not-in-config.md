---
id: 20260725104326
title: watchdog-threshold-not-in-config
principal: 1h
interest: consumers cannot tune the reclaim window without a toolkit release
hotspot: scripts/sweep.sh
business_capability: dispatch
payoff_trigger: a consumer who needs a reclaim window different from the toolkit default, or the next .smallhours.yml schema revision
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-25
---

The sweep watchdog threshold (agent-working + no open agent PR -> ready-for-human) is hardcoded with only an env override (SMALLHOURS_WATCHDOG_MINUTES, meant for testing), not a .smallhours.yml key. Chosen deliberately: DESIGN says "~1h", the implement job timeout bounds legitimate PR-less work well under it, and the consumer config schema is spec (adding keys is a maintainer decision).

**Amended 2026-07-29 (ADR 0007).** The original trigger — "a consumer whose implement runs legitimately exceed ~40m" — fired in *condition* but not in *rationale*. What happened was the toolkit raising its own implement cap 40 -> 60 and its own watchdog default 60 -> 80, after which every consumer is correctly served by the new default and none needs a knob. Promoting to config would have satisfied the letter of the trigger while adding a schema key nobody asked for. Not done.

What replaces it is worse than a missing knob, and is the real reason this entry stays open: the threshold is now the top of an ORDERED TRIPLE (ADR 0007) — watchdog (sweep.sh) > job cap (agent-loop.yml timeout-minutes) > Claude budget (derived in claude_run_budget_seconds) — spread across two files with NOTHING enforcing the ordering. Violate it and the watchdog reclaims issues out from under live runs: the sweep sets ready-for-human, the run finishes and opens a draft PR anyway, and one issue has two owners. The numbers cannot share a source: job-level `timeout-minutes` accepts expressions but not the `env` context, and Actions has no YAML anchors. A test asserting the ordering was considered and declined — it would establish a new category (workflow-YAML introspection) in a suite that is deliberately pure-logic, to guard two numbers that move roughly never. Cross-referencing comments in both files carry the invariant instead.
