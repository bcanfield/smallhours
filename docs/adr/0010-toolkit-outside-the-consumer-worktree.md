# 0010 — The toolkit checks itself out beside the consumer worktree, not inside it

**Date:** 2026-07-31
**Status:** Accepted

## Context

Every job that needs the toolkit's own files checked it out **into the consumer's
working tree**, at `$GITHUB_WORKSPACE/.smallhours-toolkit`. ADR 0005's bugfix
kept `git add -A` from committing it by appending the path to
`.git/info/exclude`.

That works for git and for nothing else. `.git/info/exclude` is not a tracked
file, so no tool that reads gitignore semantics *from the repository* can see
it — ESLint's gitignore integration reads `.gitignore` files and does not
consult it. A consumer whose checks run repo-wide therefore walks straight into
our sources and fails on code that is not theirs.

The verify gate (ADR 0008) is what made this visible. Before it, nothing in the
consumer repo ran repo-wide tooling during the agent phase, so the checkout was
invisible; the gate is the first thing to look at the whole tree.

**Evidence.** mediamtx-connect ran issue #206 through the loop three times, and
all three agents independently hit this, diagnosed it, and added the same ignore
— PRs #307, #308 and #310. Each discovery cost a **verify-gate re-entry**: a
whole extra Claude stage, on every consumer, until they happen to commit an
ignore of their own.

It is not ESLint-specific and not JavaScript-specific. Anything that walks the
tree is exposed: type-check globs, test discovery, formatters, YAML and markdown
linters (we ship a lot of both), licence and dead-code scanners. ESLint is
simply what the first consumer happened to run.

## Decision

**Nothing of ours lives in the consumer's tree.** Each job checks the toolkit
out as before, then moves it to `$RUNNER_TEMP/smallhours-toolkit` and publishes
that path as `$SH_TOOLKIT` via `$GITHUB_ENV`. Every later step invokes the
toolkit through `$SH_TOOLKIT`.

Two mechanical constraints shaped the implementation, and both are worth knowing
before anyone tries to simplify it:

1. **`actions/checkout`'s `path` must be under `$GITHUB_WORKSPACE`** — it
   rejects anything outside. Hence checkout-then-move rather than checking out
   to the destination directly. The alternative, cloning the toolkit by hand,
   gives up the action's ref resolution, auth and retries to save one step.
2. **`uses:` accepts no expressions, and `uses: ./…` resolves against the
   workspace.** So the `consumer-config` composite action could not survive the
   move in any form: a local path can no longer reach it, and a remote
   `owner/repo@ref` would have to be a literal, hardcoding the toolkit repo name
   and pinning the action to a tag that drifts from `job.workflow_sha` — the
   separate versioning surface the self-checkout exists to avoid.

`consumer-config` therefore becomes `scripts/consumer-config.sh`, invoked by
absolute path. This keeps the single definition that paid off the
`config-fetch-step-duplicated` debt; only the calling convention changed.

The four `.git/info/exclude` steps are deleted. They are dead — `git add -A` in
the consumer's worktree can no longer see a directory that is not in it — and
leaving them would suggest the tree still needs protecting.

`tests/test-workflow-wiring.sh` asserts the invariants structurally: no step runs
the toolkit from inside the workspace, nothing writes `.git/info/exclude`, no
local action paths survive, and in every job the move precedes every use of
`$SH_TOOLKIT`. `agent-loop.yml` is `workflow_call`-only, so nothing in this
repo's CI ever executes it; a wrong path in one of a dozen near-identical jobs
is otherwise invisible until it runs on a consumer, against the floating tag.

## Consequences

- A consumer whose `verify:` command lints or type-checks the whole tree stops
  failing on our files. No consumer action, no re-onboarding: the checkout lives
  in the reusable workflow, so this arrives with the next `v1` move.
- The fix covers tools with no ignore semantics at all, which the `.gitignore`
  alternative would not have.
- **`$SH_TOOLKIT` is now load-bearing and arrives mid-job.** A step that reads it
  before the move expands an empty prefix. The `cancelled()` handler in
  `implement` uses `${SH_TOOLKIT:-}` deliberately — it can fire before the move —
  and the wiring test guards the ordering everywhere else.
- One extra step per job (11 of them), and the toolkit is momentarily in the
  workspace between checkout and move. Nothing runs in that window.
- Consumers who already committed a `.smallhours-toolkit/**` ignore keep a line
  that now matches nothing. Harmless; not worth a migration.
- `.github/actions/` is gone, so the toolkit no longer ships an action anyone
  could reference.

## Alternatives

- **Have onboarding write `.smallhours-toolkit/` into the consumer's committed
  `.gitignore`.** One line, fixes every gitignore-aware tool at once, and it is
  visible to the maintainer rather than hidden in `.git`. Rejected: it only
  reaches repos that re-run setup, it writes to a file the consumer owns, and it
  does nothing for tooling that honours no ignore file — the directory is still
  sitting in their tree. It treats the symptom.
- **Document it in `GETTING-STARTED.md`.** Cheapest. Rejected because the trap's
  first trigger costs a Claude stage, and docs about a trap are read after
  hitting it more often than before.
- **Leave it.** Defensible on the numbers — the agent does diagnose and fix it,
  and once a consumer commits the ignore it never recurs, so the cost is bounded
  to one re-entry per consumer. Rejected because "bounded" still means every
  adopter pays a wasted stage to learn something we already know, and the three
  independent rediscoveries show it is not a fluke.
- **Clone the toolkit directly into `$RUNNER_TEMP`** instead of checkout-then-
  move. One step instead of two. Rejected for giving up `actions/checkout`'s ref
  handling, auth and retry behaviour for a cosmetic saving.
- **Keep the composite action and check the toolkit out twice** — once inside the
  workspace for `uses:`, once outside for the scripts. Rejected on sight: it
  reintroduces the exact directory this ADR removes.

## Payoff trigger

Revisit if `actions/checkout` ever accepts a destination outside the workspace,
which would collapse the move step. Revisit the deleted `.git/info/exclude`
steps only if something is ever deliberately placed back in the consumer's tree
— in which case this ADR is what says why that is expensive.
