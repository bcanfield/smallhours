---
id: 20260717235154
title: cross-repo-edges-unsupported
principal: unknown
interest: unknown
hotspot: scripts/dispatch.sh
business_capability: dispatch
payoff_trigger: unknown
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-17
---

ADR 0006 treats a cross-repo blocking reference (owner/repo#N in a Blocked by section) as unresolvable in v1: the dependent stays blocked with a one-time comment, never dispatched. Multi-repo ticket DAGs therefore stall at the repo boundary until a human intervenes. Deliberate v1 scoping since smallhours is multi-repo but per-repo-loop by design.
