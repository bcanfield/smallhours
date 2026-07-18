---
id: 20260717235154
title: reopened-blocker-race
principal: unknown
interest: unknown
hotspot: scripts/dispatch.sh
business_capability: dispatch
payoff_trigger: Phase 2 sweep (M7) lands — sweep should detect a reopened blocker while a dependent is agent-working
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-17
---

ADR 0006 accepts a Phase-1 race: a blocker reopened while its dependent is still queued re-blocks automatically, but a blocker reopened while the dependent is already agent-working goes unnoticed — the dependent's run continues against a premise that just became unstable. Left to the Phase 2 sweep to detect and reconcile.
