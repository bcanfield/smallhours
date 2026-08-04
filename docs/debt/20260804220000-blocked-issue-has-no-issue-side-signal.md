---
id: 20260804220000
title: blocked-issue-has-no-issue-side-signal
principal: unknown
interest: unknown
hotspot: scripts/dispatch.sh
business_capability: dispatch
payoff_trigger: a second maintainer report of "I labeled it ready-for-agent and nothing happened"
quadrant: prudent-deliberate
category: observability
ai_authored: true
created: 2026-08-04
---

ADR 0006 rules that the native issue-relations UI is the whole observability
story for a blocked issue — no marker label, no summary comment, both rejected
as noise. Its own Consequences section flags the residual: a blocked queued
issue is visually identical on the label axis to one merely waiting for a slot.

That residual came due on mediamtx-connect#295: labeled `ready-for-agent`,
held every tick since on an open blocker (#292, itself never authorized), and
read by the maintainer as a loop that had failed to fire. The `Blocked by #292`
GitHub renders is a panel you have to already suspect to go look at, and it
does not distinguish "waiting" from "waiting forever because nothing in this
chain is authorized".

The run log now names what holds each queued issue (`edges_held`), which makes
the state diagnosable in one click but only *after* someone thinks to open the
dispatch job. Whether the issue itself should say so — and how that squares
with ADR 0006's noise ruling — is a maintainer decision, not a code fix.
