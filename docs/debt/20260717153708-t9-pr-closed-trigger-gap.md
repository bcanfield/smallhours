---
id: 20260717153708
title: t9-pr-closed-trigger-gap
principal: 1h
interest: T9 silently never fires until wired
hotspot: scripts/cancel.sh
business_capability: planning
payoff_trigger: Milestone 3 routing / Milestone 4 stub
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-17
---

cancel.sh implements the `pr-closed` mode (T9: PR closed unmerged -> issue ready-for-human), but the Phase-1 stub and the M3 routing table declare no `pull_request: [closed]` trigger, so nothing calls it yet. DESIGN lists T9; the plan's routing table omits it. The portable logic is done; the event wiring is an M3/M4 task. Flagged to the maintainer in the M2 summary.
