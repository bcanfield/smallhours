# Getting started

Everything you need to onboard a repo and understand what the system will
and won't do on its own. The [README](../README.md) is the short version;
this is the operator's version.

## Prerequisites (one-time, human)

1. **A dedicated GitHub App** (the "Fixer"): the identity every automation
   action runs under. Create it with Repository permissions: Contents R/W,
   Issues R/W, Pull requests R/W, Actions Read. Install it on each repo you
   onboard (this part is manual; setup reminds you).
2. **Three repo secrets** on the consumer repo:
   `AGENT_APP_ID`, `AGENT_APP_PRIVATE_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`
   (a Claude subscription token). `setup-repo.sh` verifies they're present
   and tells you which are missing.
3. **A CI workflow.** The loop keys off your existing CI; green/red is one
   of the two signals that drive everything.

## Onboarding

```sh
setup/setup-repo.sh <owner/repo> [--ci-workflow NAME] [--required-checks a,b] [--skip-protection] [--dry-run]
```

Runs with your own `gh` auth (needs `repo` + `workflow` scopes) and does,
in order: verify the three secrets, create the label vocabulary (state axis,
PR markers, category), land the stub workflow and a default `.smallhours.yml`
wired to your CI name (via PR if your default branch requires PRs), enable
secret-scanning push protection, and set branch protection unless the branch
is already covered by a ruleset.

Afterwards, and any time something feels off:

```sh
setup/doctor.sh <owner/repo>
```

re-checks every precondition plus stub version drift, and exits nonzero on
any failure, so it is safe to run in a scheduled audit.

## Configuration

Per-repo behavior lives in `.smallhours.yml` at the repo root. All keys are
optional; the full schema with defaults is at the bottom of
[`IMPLEMENTATION-PLAN.md`](IMPLEMENTATION-PLAN.md). The knobs you're most
likely to touch:

- `models` / `max_turns`: which Claude model runs each stage, and how long
  it gets.
- `max_concurrent`: how many issues may be in `agent-working` at once.
- `attempt_cap`: how many consecutive tries the agent gets at red CI before
  giving up.
- `ci_workflow`: the workflow name the loop treats as the gate.
- `egress_extra_domains`: extra hosts appended to the sandbox allowlist
  (e.g. your package registry).
- `labels`: map canonical label names to your repo's existing strings.

The defaults are meant to be good enough that you rarely open this file.

## How the loop behaves

Two signals drive every state change: **CI results** and **formal reviews**.
Plain PR comments do nothing; only a "Request changes" review from a user
with write access re-summons the agent.

- **Red CI**: the agent gets a bounded number of consecutive fix attempts
  (`attempt_cap`, default 3; the counter resets on any green). When it runs
  out, the issue moves to `ready-for-human` and the agent stops.
- **Request changes**: the PR goes back to draft, the issue back to
  `agent-working`, and the agent revises.
- **Green and mergeable**: the PR flips to ready and the issue moves to
  `in-review`: your queue.
- **Merge**: the issue closes, the branch is deleted.
- **Impossible task**: no commits means no ghost PR; the issue moves to
  `ready-for-human`.
- **Cancel**: close the issue (or pull the `ready-for-agent` label)
  mid-run and the PR closes, the branch is deleted.

Two invariants make the boards trustworthy: every issue carries exactly one
state label at all times, and a PR is either draft (automation's problem) or
ready (yours), nothing in between.

## The trust boundaries

- The agent runs inside a network sandbox with an egress allowlist: GitHub,
  the Claude API, and whatever you add via `egress_extra_domains`. A
  prompt-injected issue has very few places to send anything.
- Human approval is structurally required by branch protection; the agent
  cannot approve or merge its own work.
- Every automation action is performed by the Fixer App, so the audit trail
  always distinguishes machine actions from yours.
- Residual risk is deliberate and documented: only label issues you
  understand as `ready-for-agent`. See the risk register in
  [`IMPLEMENTATION-PLAN.md`](IMPLEMENTATION-PLAN.md).

## Going deeper

- [`DESIGN.md`](DESIGN.md): the full design: both state machines, every
  transition, the edge cases and their rulings.
- [`IMPLEMENTATION-PLAN.md`](IMPLEMENTATION-PLAN.md): build status,
  milestone by milestone, plus the config schema and risk register.
- [`adr/`](adr/): the hard-to-reverse decisions, and why they went the way
  they did.
