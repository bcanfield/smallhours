---
id: 20260724215130
title: trigger-labels-not-mappable
principal: 1d
interest: unknown
hotspot: scripts/lib/config.sh
business_capability: dispatch
payoff_trigger: a consumer actually needs to rename ready-for-agent / agent-working / agent
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-24
---

The labels: mapping (ADR 0006 / ticket 06-1) cannot remap ready-for-agent, agent-working, or the PR marker agent: the reusable workflow gates on them in expression-time `if:` clauses, where consumer config is unreadable. config_load rejects an attempted remap loudly rather than leaving a silently dead trigger. Lifting the constraint means moving the label comparison into an in-job step (config fetch + resolve), costing one runner spin-up per label event on every consumer issue.
