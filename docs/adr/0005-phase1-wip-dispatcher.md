# 0005 — a bounded work queue: WIP-limited dispatcher in Phase 1

**Date:** 2026-07-18
**Status:** Accepted

## Context

M5 dogfooding exposed a blast-radius problem: applying `ready-for-agent` to ~17
issues at once fired ~17 parallel `implement` runs (per-issue concurrency
isolates issues but caps nothing globally) — N Claude runs, N PRs, N× token
spend from one bulk label action. The maintainer's actual need is a **bounded
work queue**: `ready-for-agent` can be arbitrarily deep, but only a few issues
should be worked concurrently; the rest wait and start as slots free.

A self-draining queue needs a **dispatcher** — something that notices "a slot
freed, promote the next one." The design deferred the scheduled sweep to Phase 2
(M7); this requirement pulls a *minimal* dispatcher forward into Phase 1.

## Decision

- `ready-for-agent` becomes a **queue** of validated issues. `authorize.sh` no
  longer starts work — on grant it leaves the issue `ready-for-agent`; on deny
  it fails closed as before.
- A **dispatcher** (`dispatch.sh`) is an idempotent reconciler: count issues in
  `agent-working` (`W`), read `max_concurrent` (`.smallhours.yml`, default 3,
  `K`), and promote the `K − W` oldest queued issues (issue-number ascending, a
  FIFO proxy) to `agent-working`. It runs under one **global** concurrency group
  (`smallhours-dispatch`), so only one instance runs and the slot count can't
  race. Triggered on the **`schedule`** tick (drains as slots free) and right
  **after a successful authorize** (starts a just-queued issue promptly).
- Promotion sets `agent-working`; because the App applies it, the label event
  re-triggers the **implement** route (label-chain), **guarded** by "no open
  `agent` PR" so an address-review re-summon (which also sets `agent-working`)
  doesn't spuriously start a fresh implement.
- The cancel route's unlabel path is gated to `sender.type == 'User'`: the App
  removes `agent-working` on every normal transition, and that must not read as
  a cancellation (T11 is a *human* pulling the label).

## Consequences

- One bulk label action can never exceed `K` concurrent runs; excess simply
  waits in the queue and drains automatically. Blast radius is bounded and the
  review load is bounded.
- A thin slice of the Phase 2 sweep now lives in Phase 1; the full sweep (M7)
  will subsume and extend this dispatcher (branch-behind, watchdog, label
  reconciliation).
- Drain latency is up to one schedule interval (~15 min) after a slot frees.
  Acceptable for an unattended overnight system.
- `ready-for-agent` semantics shift from "start now" to "queued"; the stub is
  unchanged (all logic rides existing triggers behind `@v1`).
- A stuck `agent-working` issue (dead runner) holds a slot until the Phase 2
  watchdog reclaims it — accepted for Phase 1.

## Alternatives

- **Global concurrency group on `implement`** — 2 lines, but with
  `cancel-in-progress: false` each newly-pending run cancels the prior pending
  one, so most bulk-labelled issues are **silently dropped** (the exact
  "re-labelled issue never gets worked" failure spike 0b was built to catch).
  Rejected on correctness.
- **Event-driven promotion** (promote on `agent-working` exit) — instant, no
  scheduler, but smeared across every exit point and stalls with no self-healing
  if an event is missed. Rejected for fragility.
- **`repository_dispatch` fan-out** — explicit and unambiguous, but adds a
  trigger to the consumer stub, so every onboarded repo must re-sync (ADR 0002
  stub drift). Rejected in favour of the label-chain, which needs no stub change.

## Payoff trigger

Revisit when the Phase 2 sweep (M7) lands — it should absorb this dispatcher.
Re-tune the `max_concurrent` default after real multi-issue usage.
