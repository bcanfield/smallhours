---
id: 20260725104326
title: watchdog-threshold-not-in-config
principal: 1h
interest: consumers cannot tune the reclaim window without a toolkit release
hotspot: scripts/sweep.sh
business_capability: dispatch
payoff_trigger: a consumer whose implement runs legitimately exceed ~40m (would need a longer window), or the next .smallhours.yml schema revision
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-25
---

The sweep watchdog threshold (agent-working + no open agent PR -> ready-for-human) is hardcoded at 60 minutes with only an env override (SMALLHOURS_WATCHDOG_MINUTES, meant for testing), not a .smallhours.yml key. Chosen deliberately: DESIGN says "~1h", the implement job timeout (40m) bounds legitimate PR-less work well under it, and the consumer config schema is spec (adding keys is a maintainer decision). If a consumer ever raises the implement timeout past ~55m, the watchdog would reclaim live runs — that is the moment to promote this to config.
