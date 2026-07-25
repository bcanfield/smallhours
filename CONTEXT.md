# CONTEXT.md — Ubiquitous language

Glossary for the autonomous issue → PR system. Terms here are canonical; use
them exactly in code, labels, docs, and conversation.

## Terms

**Grilling (a.k.a. triage)** — The external process that turns a raw idea into a
fully described issue. Happens *outside* this system. This system never sees an
issue until grilling is complete.

**Fully described issue** — The artifact grilling produces: goal, concrete
acceptance criteria, file hints, constraints. The input contract of this system.

**Category label** — One axis of the two-axis label taxonomy: `bug` /
`enhancement`. Applied during grilling, used as-is by this system.

**State label** — The other axis: every triaged issue carries **exactly one**
state label at any time. Triage-owned states: `needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`, `wontfix`. System-owned states:
`agent-working`, `in-review`. Terminal state is the issue being closed (merged
PR or not-planned).

**`agent-working`** — State label set the moment the system accepts a
`ready-for-agent` issue. Deliberately coarse: covers implementing, CI-fixing,
and conflict-resolving. Fine-grained progress is expressed on the PR, never as
issue states.

**`in-review`** — State label meaning the PR is ready and the maintainer's
review is the only thing pending. The maintainer's queue.

**Request-changes re-summon** — Submitting a formal "Request changes" review on
an agent PR automatically re-summons the agent (PR back to draft, issue back to
`agent-working`). Only formal reviews from write+ users trigger this; plain PR
comments never do.

**`agent` (PR label)** — Ownership marker on pull requests: "automation owns
this PR and may modify it." Not a state. Distinct from the issue state axis.

**`ready-for-agent`** — The state label that is this system's trigger. Applying
it means: the issue is grilled, fully described, and the maintainer authorizes
spending tokens on it.

**`ready-for-human`** — State label for work that needs a person, not the agent.
Candidate mapping for "automation gave up" outcomes.

**Blocking edge** — A declared dependency between issues: the blocked issue
must not be worked until the blocker is **cleared**. Canonically a native
GitHub issue dependency; a `## Blocked by` body section is input that gets
normalized into one (ADR 0006).

**Cleared (edge)** — A blocking edge whose blocker is closed as completed
(merged PR or hand-closed done). A blocker closed not-planned does *not* clear
the edge — it moves dependents to `ready-for-human` (plan change).

**Promotable** — A `ready-for-agent` issue all of whose blocking edges are
cleared. The dispatcher promotes only promotable issues; an issue with no
edges is trivially promotable.

**Parent spec** — The spec document a ticket was cut from (the `/to-spec`
artifact). A ticket names it with a body line `Spec: <#issue | path | URL>`;
the implement pre-step inlines it verbatim into the agent's context (ADR
0006). No `Spec:` line means no parent spec — plain issues are unaffected.

**Maintainer** — The human (initially only Brandin) who grills issues, applies
`ready-for-agent`, reviews PRs, and merges. The only actor with write access who
participates manually.

**Agent** — Claude Code running unattended (GitHub Actions in v1), implementing
a `ready-for-agent` issue through to a reviewable PR.

**Toolkit repo** — The single public repo owning all shared automation logic
(reusable workflows, scripts, tool-version pins, onboarding scripts). The only
place behavior changes are made.

**Consumer repo** — A repo the loop operates on. Carries only a stub and a
config file; never automation logic.

**Stub** — The thin per-consumer-repo workflow file GitHub structurally
requires: triggers, permissions ceiling, one versioned `uses:` reference to the
toolkit, secret wiring. Deliberately kept too thin to need syncing.

## Invariants

- Exactly one state label per triaged issue at all times; transitions replace,
  never accumulate.
- All loop state lives in GitHub itself (labels, draft status, comments,
  branches) — never in runner-local or Actions-specific state — so the runtime
  can later move to self-hosted hardware without migration.
