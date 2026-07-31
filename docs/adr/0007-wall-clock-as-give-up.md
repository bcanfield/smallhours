# 0007 — Wall-clock exhaustion is a give-up, not a cancellation

**Date:** 2026-07-29
**Status:** Accepted

## Context

Two mediamtx-connect implement runs (#175, #177) were cancelled at the 40-minute
job cap. Cancellation is not a failure, so `if: failure()` never fired: no
diagnostics artifact. `implement.sh` never reached its give-up path: no handback
comment, no state change, and the working tree died with the runner. The issues
sat in `agent-working` until the watchdog reclaimed them — which needs a
*scheduled* sweep, and GitHub's `*/15` cron was observed lagging up to 65
minutes. Two of three `max_concurrent` slots were held for over an hour on runs
that no longer existed. Roughly 80 minutes of Opus produced no branch, no PR, no
comment and no diagnostics.

The system already knows how to quit well. A **give-up** posts a reason
synthesized from what the machine knows, sets `ready-for-human`, and uploads the
result JSON. Cancellation bypasses all of it, so the *worst-instrumented* exit
was the one the longest, most expensive runs took.

`max_turns` was not the binding constraint. It had been ratcheted 50 → 75 → 100
across the rollout on genuine `error_max_turns` evidence, but these two runs
never approached the turn cap. They ran out of clock.

Three constraints shaped the response:

- **The job cap cannot be consumer-tunable.** `timeout-minutes` is evaluated
  before any step runs, so it cannot read `.smallhours.yml`. Making it an input
  means a `workflow_call` parameter and a stub edit in every consumer repo —
  precisely what the thin-stub contract and ADR 0002 exist to prevent.
- **A partial branch must not become a pull request.** An `agent` PR with red CI
  feeds the auto-fix loop, which would spend up to `attempt_cap` further runs
  trying to green a half-implemented change.
- **Provisioning cost varies.** `claude_run_provision` (apt-get, the Claude
  installer, `npm -g sandbox-runtime`) takes a minute on a warm runner and
  several on a cold one — and it is charged to the same job cap as the agent.

## Decision

**Wall-clock exhaustion is modeled as a give-up cause, not a new outcome.** No
new state label, no new vocabulary, no change to the state machine.

1. **The stage runs under `timeout --kill-after=30s`** with a budget that
   expires *below* the job cap, so the process fails rather than being
   cancelled, and every existing give-up mechanism runs.
2. **The budget is derived, not a literal**: `cap − elapsed − tail`, where the
   job stamps its own start into `$GITHUB_ENV` as its first step. Provisioning
   overrun therefore eats the agent's time instead of the tail (commit, push,
   open-pr, report-usage) that must survive for a timeout to leave anything
   behind. Absent `SMALLHOURS_JOB_CAP_MINUTES` — or absent GNU `timeout` — the
   stage runs uncapped, so `implement.sh` stays runnable outside Actions.
3. **`claude_run` synthesizes the terminal result event** the CLI never emitted:
   `{subtype: "error_timeout", is_error: true, num_turns, duration_ms,
   budget_seconds, _synthesized: true}`. `type:"result"` is written only when a
   run *ends*, so without this every downstream reader — digest, report-usage,
   the artifact, and above all `claude_give_up_reason` — falls back to "failed
   before producing a result", reintroducing verbatim the defect that fallback
   was written to eliminate.
4. **The reason names no config knob.** Unlike `error_max_turns`, whose remedy
   is `max_turns.<stage>`, a timeout has no consumer-tunable setting by
   decision (1). The only honest remedy is a smaller ticket, so that is what the
   handback says.
5. **A run cut off mid-task pushes its branch, never a pull request.** The
   comment names the branch. `state-manager` finds no PR for it and does
   nothing, so the auto-fix loop is never entered. *(Amended — see below. This
   originally read "a timed-out run", which was too narrow.)*
6. **The implement job hands the issue back on `cancelled()`**, covering the
   residual window where cancellation still happens (and a human cancelling
   from the Actions tab, which likewise hands back — deliberate).
7. **The implement cap rises 40 → 60**, alone. `address_review`, `auto_fix` and
   `resolve_conflict` stay at 40: none has been observed near its limit, and
   raising them on implement's evidence would be guessing — the same reasoning
   used when the turn caps moved.

### The ordered triple

Three numbers in three files are load-bearing on each other:

```
watchdog (sweep.sh, 80m)  >  job cap (agent-loop.yml, 60m)  >  Claude budget (derived)
```

The watchdog must exceed the cap plus dispatch and runner-queue slack, or it
reclaims issues out from under live runs — marking `ready-for-human` while the
run continues and later opens a PR, leaving two owners for one issue. The budget
must sit below the cap or the timeout never fires and cancellation returns.
Nothing enforces this ordering: the numbers cannot share a source, because
job-level `timeout-minutes` accepts expressions but not the `env` context, and
Actions has no YAML anchors. It is held by cross-referencing comments in both
files and by this ADR.

## Consequences

- A timed-out implement run now leaves: a handback comment naming the cause, the
  turn count and the branch; a diagnostics artifact; a pushed branch with the
  partial work; and a freed WIP slot. Previously: nothing.
- `num_turns` on an `error_timeout` becomes the calibration instrument. High
  turns means the agent was thrashing; low turns over a full budget means it was
  grinding through genuinely large work. This is the evidence that will say
  whether 60 minutes is the right cap — there is currently none.
- Worst-case strand time for a genuinely dead runner rises from ~60m to ~80m
  (plus cron lag). Accepted, because `cancelled()` now covers the common case
  and only a runner that dies before any step runs reaches the watchdog.
- Orphaned `agent/issue-N` branches accumulate on consumers, with no PR to close
  them and no reaper. Registered as debt.
- A run on a pathologically slow runner gets a shorter budget and may time out
  for reasons unrelated to ticket size. Mitigated by logging the computed budget
  next to `stage=`/`model=`/`max_turns=`, so a short budget is visible rather
  than inferred.

## Alternatives

- **Leave the cap at 40 and rely on ticket sizing alone.** Rejected by the
  maintainer: the evidence that 40 is sufficient does not exist either, and
  splitting is a slower feedback loop than raising a number once.
- **Raise the cap for every stage.** Rejected: it inflates the blast radius of
  four stages to fix the one that has evidence.
- **Make the cap a `workflow_call` input.** Rejected: costs a stub revision
  across every consumer and a `doctor.sh` drift bump, to gain a knob whose
  correct value is currently a guess.
- **Change the diagnostics upload to `if: always()`.** Rejected as a shortcut
  that is also a regression: the artifact path `smallhours-result.json*` matches
  the raw event stream, which `claude_run` deletes on every normal exit but not
  on a cancel — so `always()` would upload file contents and command output that
  are explicitly never meant to leave the runner.
- **Open the draft PR early, after a first commit.** Rejected: there is no first
  commit. `prompts/implement.md` forbids the agent from committing or pushing,
  and the system commits once after the agent stops — the property `open-pr.sh`
  is built on. Opening a PR early also feeds partial work to auto-fix.
- **Checkpoint-and-resume onto the same branch.** Deferred, not rejected. It is
  the only option that recovers the *spent* time rather than the artifact, but
  it changes the attempt/branch model (`sweep_next_attempt`) and is unjustified
  until there is evidence that properly-sized tickets still exceed the cap.

## Amendment 2026-07-30 — preservation covers both allowances, not just the clock

Decision 5 originally preserved partial work only on `error_timeout`. The first
run after release proved that wrong at a cost of $6.20.

mediamtx-connect#291 — the *smallest* ticket of the #175 re-cut, a read-only
catalog page — gave up at **101 turns against a cap of 100, in 18 minutes**. It
was not thrashing: the tool digest shows codebase archaeology followed by a
complete vertical slice (contract, API router + test, page + test, routes, nav,
`FEATURES.md`, two e2e specs, i18n), with its final turns spent on `git diff`
self-review. It ran out of allowance roughly one turn from finishing, and
because the preservation test named only `error_timeout`, fifteen files of
finished work died with the runner — the exact loss this ADR exists to prevent,
reproduced through the door left open next to the one that was closed.

The two allowances are the same event with different meters, and their give-up
reasons already said so in identical words: *"cut off mid-task — it did not fail
on any single step."* Which one bites is a property of the **work**, not the
ticket: fast exploratory turns exhaust the turn cap first (#291, 5.6 turns/min),
slow heavy turns exhaust the clock first (#175, #177 — 40 minutes without ever
reaching the turn cap). Raising the wall clock to 60 would not have saved #291
by a single second.

The predicate now lives in `claude_was_cut_off` beside the give-up semantics
rather than inline in `implement.sh`, and `tests/test-claude-run.sh` pins both
subtypes so it cannot narrow again. Every other give-up is unaffected: a run
that stopped deliberately has an empty tree and `_capture_work` returns 1.

**Consequence for the turn cap.** A wall-clock budget now bounds spend directly,
so `max_turns` is no longer the backstop against a runaway agent and should sit
well above real work instead of acting as a second budget. mediamtx-connect
raised `max_turns.implement` 100 → 200 on this evidence.

## Payoff trigger

Revisit when `error_timeout` handbacks accumulate on tickets that already meet
the sizing standard (one deliverable, no conjunction in the title) — that is the
signal that the cap, not the ticket, is wrong, and the point at which
checkpoint-and-resume or a `workflow_call` input starts to earn its cost.
