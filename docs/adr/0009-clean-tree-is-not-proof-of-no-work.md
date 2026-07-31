# 0009 — A clean working tree is not proof the agent did nothing

**Date:** 2026-07-30
**Status:** Accepted

## Context

mediamtx-connect#307. The agent's code was correct and every code check passed
— Build, E2E, Docker image smoke all green. One check was red: **the pull
request title.** `open-pr.sh` titles a PR from its issue title verbatim, and
issue #206 was called "Record toggle has no pending/optimistic state", with no
conventional-commit prefix. That repo squash-merges, so the PR title *is* the
commit subject semantic-release parses; an unprefixed title silently drops the
change out of the next release, which is why the check exists.

The `auto_fix` stage then did exactly the right thing: it retitled the PR to
`fix(streams): show pending state on record toggle`, classified it `fix` with a
stated reason, noted that it had deliberately made no code changes — and the
check went green on the next run.

The toolkit gave up on it anyway:

> 🛑 smallhours could not auto-fix the failing CI.
> **Reason:** the agent made no changes, so there is nothing to re-run CI on.

PR → `human-needed`, issue → `ready-for-human`. A pull request with green code
checks and a now-correct title was handed to a person as a failure, having spent
one of three attempts.

The bug is one line: `auto-fix.sh` read an empty `git diff --cached` as "the
agent could not fix it". That inference is sound for a code failure and wrong
for every failure whose repair lives **outside the tree** — a PR title, a
re-run of a flaky job. `auto_fix` could only express a repair as a commit, so
the toolkit's model of what the agent did was narrower than what the agent could
actually do. Note that the agent's own summary said plainly what it had done and
why; the information needed not to give up was in the result the toolkit was
already reading, and the toolkit had nowhere to put it.

Two facts framed the fix. First, `GH_TOKEN` (the Fixer App token) is exported
into the Claude process, so the "do NOT push, do NOT open or merge pull
requests" line in `prompts/auto-fix.md` is a request, not a boundary — the agent
retitled the PR because it *could*, and the prompt had no opinion about titles.
Second, a retitle re-runs CI only where the consumer's workflow triggers on
`pull_request: edited`. mediamtx-connect's does, and skips its expensive jobs
for that event — a sensible optimisation that leaves the newest run `success`
with Build/E2E `skipped` and the real green results in the *previous* run.

## Decision

### 1. The agent may repair a pull request title, and nothing else

`prompts/auto-fix.md` grants an explicit, narrow licence: fix the title with
`gh pr edit --title` when the title is what is broken, and say so in the final
summary. The body, the labels and the PR's state stay off-limits — the body
carries `Closes #N`, which closes the issue on merge.

This is a widening, and it is deliberate. The alternative was to keep the agent
a pure proposer and have the toolkit perform every out-of-tree write, which
re-narrows the model to repairs the toolkit can enumerate in advance — the exact
shape of the defect. The token is already in the environment; a prompt that
pretends otherwise buys no safety, only surprise.

### 2. The toolkit decides by observing the pull request, never by trusting a claim

`auto-fix.sh` snapshots `title`, `body` and `statusCheckRollup` **before** the
agent runs and diffs against them after. With the tree clean:

| observation | outcome |
|---|---|
| a check is queued/running, or the check digest changed | **out-of-tree** — a repair happened; exit 0 and let the CI event path own the PR |
| the title changed but CI has not moved | **stranded** — hand off, naming the cause |
| nothing on the PR moved at all | **no-changes** — the original give-up, unchanged |

`stranded` is re-asked, not acted on, for up to 120s: a run triggered by a
retitle takes a moment to appear. If nothing starts in that window, the hand-off
comment says *why* — the consumer's CI does not run on `pull_request: edited`,
so the corrected title will never be re-checked — instead of blaming the agent.

The decision is made from observation rather than from the agent's declaration
because a claim the toolkit cannot check is not evidence. The agent's summary is
still quoted in every comment; it is prose, not authority.

An `out-of-tree` outcome posts a short comment naming what changed. Without it
the only trace of the attempt is an `autofix-attempt-N` label and the Actions
tab, which is the complaint that produced `claude_give_up_reason`.

If the body changed, it is restored from the snapshot. That makes the licence in
(1) an invariant rather than a request, in a case that should never occur.

The verdict itself is pure (`lib/autofix.sh`) and fixture-tested in
`tests/test-autofix.sh`; the seam around it — snapshot, run, diff, route — is
driven end to end against stubbed `gh`/`claude` in
`tests/test-autofix-cleantree.sh`, for the reason ADR 0007 recorded the hard
way: a decision nothing exercises ships broken with its unit tests green.

### 3. `conventional_title_types` — stop spending an attempt on a prefix

A new optional `.smallhours.yml` key maps an issue label to a commit type:

```yaml
conventional_title_types: { bug: fix, enhancement: feat }
```

**Presence is the opt-in.** Absent — the default, and every existing consumer —
titles pass through verbatim; a repo that does not use conventional commits must
never have prefixes invented for it. A title that already carries a real type is
left alone, where "real" means the conventional-commits standard vocabulary plus
whatever the consumer's own map declares (so "Streams: record toggle broken"
is prose and still gets prefixed, while "docs: fix a typo" does not).

**When no label maps, the title is left verbatim.** Guessing `chore:` would
silently drop a feature out of the consumer's next release — precisely the harm
the check being satisfied here exists to prevent. Unprefixed instead falls
through to `auto_fix`, which can now retitle without costing a hand-off. A
ladder, not a guess.

## Consequences

- A non-code repair no longer summons a human. The class is fixed, not just the
  title case: a re-run job, or anything else that moves a check, reads the same.
- An opted-in consumer gets correct titles for free, so the common case costs
  zero auto-fix attempts rather than one of three.
- **The agent can now change a pull request title on purpose.** Prompt injection
  via issue text remains the residual risk it always was (ADR 0001); this adds
  "rewrite the PR title" to what an injected agent could do — visible in the PR
  timeline, on a draft PR nobody merges without review.
- **A hand-off can now take two minutes longer.** Only on the path that was
  about to hand off anyway.
- **Movement is not attributed.** An unrelated check completing mid-run reads as
  `out-of-tree` and the stage exits clean. Deliberate — an event *is* live — but
  if that event belongs to a workflow the toolkit does not gate on, the PR can
  sit `ci-failing` with nobody watching. Registered as debt.
- The label→type map is the consumer's judgement, applied without reading the
  change. An issue labelled `enhancement` that turns out to be a bugfix ships as
  `feat:` and lands in the wrong release section.
- One more config key to document, and one more thing `prompts/auto-fix.md` has
  to say precisely.

## Alternatives

- **Let `auto_fix` report "fixed, no commit needed" as a structured outcome**
  (the issue's option 2). Expresses intent exactly and covers repairs the
  toolkit cannot observe. Rejected as the *decider*: acting on an unverifiable
  claim is how a PR gets promoted on a mistake. The claim survives as prose in
  the comment; the check run decides.
- **Keep the agent a pure proposer; the toolkit performs every out-of-tree
  write.** Preserves "the agent proposes, the toolkit disposes" and makes every
  GitHub mutation auditable in toolkit code. Rejected because it only ever
  covers repairs someone enumerated in advance — the defect this ADR exists to
  remove. Reconsider if the licence in (1) is ever abused.
- **Strip `GH_TOKEN` from the Claude process** (as `verify.sh` already does for
  the verify command), making the old prompt rule enforceable. Genuinely
  stronger, and rejected only because the auto-fix agent legitimately reads CI
  state and logs with `gh` mid-run. Worth revisiting if a read-only token
  becomes easy to mint.
- **Exit 0 immediately on any out-of-tree repair, no wait.** Smallest diff.
  Rejected: `sweep_reeval_pr` only rescues PRs whose latest run is *green* and
  the watchdog only reclaims issues with *no* open PR, so a PR that re-fires
  nothing would sit unowned indefinitely.
- **A sweep pass for stranded `ci-failing` PRs.** The most robust backstop, and
  it would catch strands from causes nobody predicted. Deferred as its own
  threshold and its own pass, well beyond this issue; the 120s window bounds the
  risk to the job that caused it.
- **Derive the PR title from the agent instead of from labels** — it has just
  written the change and knows whether it is a fix or a feature. Rejected:
  `open-pr.sh` is the deterministic tail of T1, and this string becomes a
  release.
- **Parse a declared type out of the issue body** (#206 literally said "Ships as
  `fix:`"). Uses information that already exists, but as prose it needs a regex
  over free text, and as a convention it needs a marker syntax no issue author
  has been asked for. Revisit from the `/to-tickets` side, where the declaration
  is written.

## Payoff trigger

Build the sweep pass for stranded PRs if a `ci-failing` agent PR is ever
observed sitting with no owner — the residual this ADR knowingly leaves. Revisit
the agent's licence (1) if it edits anything it was told not to, which the body
restore will log. Revisit the 120s window if a consumer's `edited`-triggered run
is ever observed appearing later than that.
