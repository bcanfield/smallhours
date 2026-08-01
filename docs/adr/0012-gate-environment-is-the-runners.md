# 0012 — The verify gate's environment is the runner's, not the agent's

**Date:** 2026-07-31
**Status:** Accepted

## Context

[ADR 0011](0011-verify-gate-runs-in-the-agents-shell.md) made the gate run the
consumer's command in a fully initialised shell, so a toolchain the agent
bootstrapped for itself would be visible. It works for what it targeted, and the
`gate-environment` job proves it on a real runner.

A second consumer run says that is not enough. mediamtx-connect ran an issue on
v0.5.11 with a bare `pnpm verify` and the gate still reported `pnpm` unresolved —
login shell, interactive shell and an explicit `. ~/.bashrc` all found nothing.
So on that repo the toolchain is on no default `PATH` and no rc file adds it:
whatever the agent does to reach `pnpm` leaves nothing on disk for another shell
to pick up. Decision 2 of ADR 0011 did its job — no re-entry was burned, the PR
carried the notice, the branch shipped — but the gate did not gate.

The mechanism ADR 0011 fixed (an installer appending below `~/.bashrc`'s
interactivity guard) and this one print the identical `command not found`, which
is why the original diagnosis looked complete.

This is not a tail case. It follows from ADR 0008's own choice: if the agent
installs its own toolchain inside its session, the natural outcome is a
process-local `PATH`, not an rc-file edit. An installer that writes to `~/.bashrc`
is the lucky case.

### Why environment fidelity has no bottom

The remaining candidate was sourcing Claude Code's shell snapshot
(`~/.claude/shell-snapshots/`), rejected by ADR 0011 for depending on an
undocumented internal and worth reconsidering if it were the only thing that
reaches a process-local `PATH`.

**By inspection it is not, and this reasoning is not yet backed by a measurement
on a runner** — which is what decision 2 below exists to obtain. A snapshot is
written once, at session start, and holds the `PATH` and functions that existed
*then*. A toolchain the agent fetches during its session is not in it. Worse, a
per-call route — `corepack pnpm …`, `npx pnpm`, an absolute path, an
`export PATH=… && pnpm …` compound inside a single Bash call — leaves nothing in
any environment at all, snapshot included. The most faithful artefact available
is faithful to the wrong instant.

Chasing further fidelity means chasing a process that has already exited, through
internals no contract promises. The alternative is to stop chasing and say what
the gate's environment is.

## Decision

### 1. The gate's environment is the runner's, and the `verify:` command must resolve its own entry point

This is a contract with the consumer, documented in `GETTING-STARTED.md`: invoke
through a launcher the runner is guaranteed to have (`corepack`, `npx`, `./mvnw`,
`./gradlew`, `uv run`, `make`), by absolute path, or bootstrap inside the command.
It is one line of YAML, in every ecosystem.

Every alternative that would have removed that line costs the consumer the same
line somewhere else, or moves the environment under the agent's control. ADR 0011
stands unchanged: it still rescues rc-file toolchains for free, and the
`gate-environment` job still proves it.

### 2. A gate that could not run says why, in the log

When the gate never started (ADR 0011 decision 2), it now records three probes,
each keyed only on the missing name: the initialised shell's `PATH`; a bounded,
depth- and time-capped search for the name on disk; and whether sourcing the
newest Claude Code shell snapshot *would* have resolved it.

Those separate the two worlds that produce an identical message — a toolchain
that exists but no shell we run reaches (ours to fix) from one that never
outlived the agent's process (the contract's) — and they settle the snapshot
question with a measurement instead of the inference above. Log only: the pull
request gets a remedy, not a dump.

The disk search is bounded by wall clock, so it has a **third** verdict: a search
that was cut off says so and withholds judgement. Absence of evidence is what
tells a consumer the failure is theirs to fix, and a timeout is not that. The
`gate-environment` job established this is not hypothetical — a depth-6 walk of
`/usr/local` did not finish in eight seconds on a *bare* runner, before any
consumer's package store existed.

## Consequences

- The gate is only as good as the consumer's one line, and a consumer who writes
  a bare `pnpm verify` gets an honest "could not run" and no gate. That is the
  branch of #29's acceptance criteria this closes on — documented rather than
  fixed — and it is a real reduction in what ADR 0008 promised.
- No agent-authored input decides the environment its own work is checked in. A
  handshake file would have greened the gate with zero consumer config, and a
  shell function named after the command would have greened it invisibly, unlike
  a `package.json` edit that shows in the diff a human reviews.
- The onboarding example now teaches the PATH-free shape, so a new consumer meets
  the constraint before it costs a run rather than after.
- The diagnostic runs only on an already-failed path and changes no outcome, but
  it is a few seconds of `find` and one read of a Claude Code internal — the
  first thing in the toolkit to reference that path at all, read-only and with
  its absence handled.

## Alternatives

- **Agent-authored env handshake.** The implement prompt asks the agent to write
  the exports its toolchain needs; the gate sources them. The only option that
  greens the gate with no consumer config. Rejected: it puts the agent in charge
  of the environment its own work is checked in, and depends on compliance run to
  run.
- **A consumer-declared `setup:` phase** run by the toolkit before the agent, so
  both share one environment. Ecosystem-neutral and fixes both sides at once.
  Rejected: it costs the consumer the same single line as decision 1 while adding
  a config key, a phase, documentation, and a partial reopening of ADR 0008.
- **Keep chasing fidelity** — snapshot, wrapper shell, whatever reaches the
  agent's process. Rejected on the reasoning above: the target has already
  exited, and the artefacts that survive it predate the toolchain.
- **Say nothing new and let consumers discover it.** Rejected: it is what
  happened twice, and it costs a run each time.

## Payoff trigger

Revisit decision 1 if a diagnostic ever reports `it EXISTS but no shell the gate
can reach has it` — that is the world where the gate could have run and did not,
and it is ours to fix. Revisit decision 2's snapshot probe if it ever reports
`WOULD have resolved it`, which would reopen ADR 0011's rejected alternative on
evidence rather than inference.
