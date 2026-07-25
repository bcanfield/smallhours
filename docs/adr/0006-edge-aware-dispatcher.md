# 0006 — Dispatcher enforces ticket blocking edges

**Date:** 2026-07-17
**Status:** Accepted

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

**Edge representation — normalize into native relations.** Native GitHub issue
dependencies are the single canonical edge store; the promotion decision reads
only them (GraphQL). A deterministic reconcile step, run idempotently on every
dispatch tick, parses any `## Blocked by` body section and upserts missing
native relations from it. Parsing failure is loud (comment on the issue), never
a silent scheduling decision. Body text wins over manual relation deletion —
to truly remove an edge, edit the body. GitHub's own UI consequently shows
"Blocked by #A" on every ticket for free. Requires the Fixer App to hold issue
relations write permission. Rejected: union-reading both sources every tick
(prose parsing permanently on the hot path, two sources of truth); native-only
(a text-only edge is silently ignored — the exact invisible-unblock failure
this ADR exists to prevent).

**Unblock semantics — cleared means completed, not merely closed.** An edge is
cleared when the blocker is closed with `stateReason: COMPLETED` (merged PR via
`Closes #N`, or the maintainer hand-closing it done). A blocker closed
`NOT_PLANNED` is a **plan change**: each open dependent moves to
`ready-for-human` with a comment naming the dead blocker (idempotent, once) —
re-planning is human judgment, same fail-toward-human posture as T3/T4/T9.
Recovery is one label action if the dependents were actually fine. A blocker
*reopened* while its dependent is still queued re-blocks it automatically (the
reconciler recomputes every tick); reopened while the dependent is already
`agent-working` is an accepted Phase-1 race, left to the Phase 2 sweep.
Rejected: auto-clear on any close (unattended token spend on tickets whose
foundation was just deleted); blocked-forever (silent stall).

**Chains × WIP — serialize on merge.** A dependent starts only after its
blockers' changes are on `main`. Stacked PRs are out of scope (see Payoff
trigger; debt entry `chain-serialize-no-stacked-prs`).

**Malformed edges — wait on the ambiguous, eject the impossible.** An
unresolvable `## Blocked by` reference (typo, deleted issue, or cross-repo ref
— cross-repo dependencies unsupported in v1) fails closed: the issue stays
blocked, with a one-time comment naming the ref. It might resolve later, so it
waits. A **cycle** can never self-heal — no scheduling order is correct — so
the reconciler detects cycles among open queued issues (DFS on a tiny graph
each tick) and moves every member to `ready-for-human` with a comment showing
the cycle. Rejected: ignoring unparseable refs (silent unblock); parking
cycles blocked (permanent silent stall).

**Observability — the native relations UI is the observability.** Because
every edge is normalized into a native dependency, GitHub already renders
"Blocked by #N" with live open/closed status on each ticket. No `blocked`
marker label (would introduce a marker axis on issues and one more thing to
keep truthful), no summary comments (noise).

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

---

## Appendix — M5.5 spec and ticket breakdown

Recorded here by maintainer choice instead of being published to the tracker;
publish as real issues (blockers first, edges as native dependencies) when M5.5
starts, after M5 acceptance scenarios. **Published 2026-07-24** as
bcanfield/smallhours#7 (06-1), #8 (06-4), #9 (06-5), #10 (06-2), #11 (06-3),
#12 (06-6), with native dependency edges 10←7, 11←10, 12←7.

### Spec

**Problem.** smallhours cannot safely consume the output of the Pocock flow:
`/to-tickets` publishes a DAG of `ready-for-agent` tickets, but the dispatcher
is edge-blind (wrong-order dispatch) and the implementer is knowledge-blind
(ignores parent spec, glossary, ADRs, label overrides).

**Solution.** Make smallhours the Pocock flow's AFK implementer per this ADR
and DESIGN.md § Pocock protocol integration: edge-aware dispatch, deterministic
tracker-context assembly, knowledge-and-discipline prompt guidance, label
mapping, strict read-only knowledge layer.

**Implementation decisions.** All per the Decision section above, plus: the
Fixer App gains issue-dependencies write permission (operational step, verified
by doctor); `address-review.md` receives the knowledge + read-only prompt
additions but not the TDD/self-review block.

**Testing decisions.** Graph logic (promotable computation, cycle detection,
ref parsing) factored into pure functions exercised against fixture JSON;
end-to-end behavior verified as acceptance scenarios on the guinea-pig repo
(bcanfield/mediamtx-connect): chain A←B dispatches serially; NOT_PLANNED
blocker ejects dependent; unresolvable ref stays queued with one comment.

**Out of scope.** Stacked PRs; cross-repo edges; automation writing the
knowledge layer; installing skill files into the runner.

### Tickets

| #    | Ticket                   | Blocked by | Delivers                                                                                                                                           |
| ---- | ------------------------ | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| 06-1 | Label mapping            | —          | `labels:` in `.smallhours.yml` + resolver used by all scripts; canonical defaults                                                                  |
| 06-2 | Edge-aware promotion     | 06-1       | dispatch.sh upserts `## Blocked by` → native relations; promotes only promotable; unresolvable ref waits + one-time comment                        |
| 06-3 | Plan-change ejection     | 06-2       | NOT_PLANNED blocker → dependents `ready-for-human` + comment; cycle detection → members ejected + comment                                          |
| 06-4 | Tracker-context assembly | —          | implement pre-step inlines parent spec verbatim + pointer per cleared blocker                                                                      |
| 06-5 | Prompt discipline        | —          | implement.md: knowledge guidance, ADR guardrail, TDD-at-seams, closing self-review, read-only paths; address-review.md: knowledge + read-only only |
| 06-6 | Setup & doctor           | 06-1       | setup-repo.sh imports `triage-labels.md` + appends system-owned-states note; doctor checks mapping drift + App dependencies permission             |

Frontier at start: 06-1, 06-4, 06-5 (parallelizable). 06-2 → 06-3 chain and
06-6 follow 06-1.
