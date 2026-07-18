# 0006 — Dispatcher enforces ticket blocking edges

**Date:** 2026-07-17
**Status:** Accepted (mechanism); companion sub-decisions in progress — see Decision

## Context

Adopting a Pocock-aware, gracefully-degrading posture means smallhours should
consume tickets produced by `/to-tickets`: tracer-bullet issues forming a DAG,
each declaring **blocking edges** (native GitHub issue dependencies and/or a
`## Blocked by` body section), all labeled `ready-for-agent` at publication
("agent-grabbable by construction").

The Phase 1 dispatcher (ADR 0005) is edge-blind FIFO. Two failure modes:

1. **Parallel chain promotion.** Issue-number FIFO gives accidental partial
   order (to-tickets publishes blockers first), but with `max_concurrent = 3` a
   chain A←B is promoted *together* and worked in parallel — B implements
   against a tree without A's changes.
2. **Review-latency entanglement.** A blocker is not "done" when its agent
   finishes; its changes reach `main` only when the maintainer merges. A
   dependent dispatched while its blocker sits `in-review` checks out a `main`
   lacking the blocker's work. "Unblocked" therefore cannot mean "blocker's
   agent finished."

Whatever enforces edges must degrade gracefully: an issue with no edges (the
entire pre-Pocock contract) behaves exactly as today.

## Decision

**The dispatcher is edge-aware.** Promotable = `ready-for-agent` AND every
blocking edge cleared. Blocked issues simply stay queued; FIFO applies among
*unblocked* queued issues only. No edges ⇒ no blockers ⇒ today's behavior.

`ready-for-agent` remains **pure authorization**: the maintainer authorizes the
whole DAG when approving the ticket breakdown; ordering is scheduling, and
scheduling is the system's job. No automation ever applies `ready-for-agent`.

This extends the reconciler philosophy of ADR 0005: every tick re-evaluates the
full picture, so a missed event, a reopened blocker, or a bulk labeling all
converge to correct behavior within one schedule interval.

**Companion sub-decisions being grilled in this session (will be recorded here
as they land):**

- Edge representation: where edges canonically live and how the dispatcher
  reads them.
- Unblock semantics: what clears an edge — in particular a blocker closed
  *unmerged* (not planned).
- Chains × WIP: serialize-on-merge vs. stacked PRs.
- Failure modes: unresolvable references, cycles, observability of a blocked
  queue.

## Consequences

- A dependent ticket can never be worked before its blockers' changes are
  available, regardless of bulk labeling or WIP cap.
- Chain throughput is gated by maintainer review cadence (each link waits for
  the previous merge) — acceptable for an unattended overnight system; stacked
  PRs are explicitly out of scope for now.
- Blocked issues hold no WIP slot and consume no tokens while waiting.
- A blocked queued issue is visually identical to a merely-waiting one on the
  label axis; observability handled under the failure-modes sub-decision.

## Alternatives

- **Deferred labeling** — only the frontier carries `ready-for-agent`;
  automation labels dependents on merge-close. Rejected: automation would be
  *granting authorization*, eroding the security ruling that `ready-for-agent`
  is the human token-spend gate; and it is event-driven promotion, already
  rejected in ADR 0005 for fragility (missed event = silently stalled chain).
- **Convention only** — maintainer labels only the frontier by hand as things
  merge. Rejected: makes the human the dispatcher (the exact toil the system
  removes), and `/to-tickets`' default bulk labeling silently breaks it.

## Payoff trigger

Revisit when the Phase 2 sweep (M7) absorbs the dispatcher, and if deep ticket
chains make review-cadence serialization painful enough to justify stacked PRs.
