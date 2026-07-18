---
id: 20260717225903
title: wip-slot-leak-no-watchdog
principal: 2h
interest: a dead-runner agent-working issue holds a queue slot indefinitely, starving the queue
hotspot: scripts/dispatch.sh
business_capability: release
payoff_trigger: Milestone 7 sweep watchdog (agent-working + no open PR >1h -> ready-for-human)
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-17
---

The Phase-1 dispatcher (ADR 0005) counts agent-working as used WIP slots. If an implement run dies (runner death) the issue stays agent-working with no PR, holding a slot forever — and now that slots are capped, a leaked slot starves the whole queue, not just that one issue. DESIGN already plans the fix (Phase 2 sweep watchdog: agent-working + no open PR >1h -> ready-for-human); until then, a stuck slot needs manual clearing. Consider a lightweight staleness reclaim inside dispatch.sh if it bites before M7.
