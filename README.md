![smallhours](.github/hero.png)

# smallhours

Coding agents are good now. Watching one work is still a full-time job.

Prompt, watch, nudge, approve. Repeat. You traded writing the code for
staring at something else writing the code.

smallhours is for stepping out of that chair. You manage an issue board;
agents handle the implementation, unattended, in your repo's CI. Most of the
time they don't need you at all. When they do, they say so and get out of
the way.

## What it does

You write the issue properly: goal, acceptance criteria, constraints. You
apply one label, `ready-for-agent`.

Sometime later there's a draft PR waiting. Tests green. Ready for review.

Everything between the label and the review happened without you.

## How it works

The label kicks off a GitHub Actions workflow. Claude Code implements the
issue inside a network sandbox that can reach GitHub and the Claude API and
nothing else, working on its own `agent/issue-N` branch, surfacing as a
draft PR.

From there, the system listens to exactly two signals: CI, and your reviews.

Red CI? It takes a few bounded attempts to fix things, then hands the issue
back to you instead of looping forever. Submit a "Request changes" review and
the agent revises. Green and mergeable, and the PR flips to ready.

Your queue. Your call.

You approve and merge. The issue closes, the branch is deleted, and the
board moves on.

## The boundaries

Autonomy is easy to promise. Boundaries are what make it usable.

The merge button is structurally yours: branch protection requires a human
approval, and the agent can't grant one. Every automation action is performed
by a dedicated GitHub App, so history always shows who did what. And if a
malicious issue ever talks the agent into something, the sandbox leaves it
very few places to send anything.

One more small thing that matters a lot. Every issue carries exactly one
state label at all times, so the board never lies. Each item is the
automation's problem, or it's yours.

## Getting started

```sh
setup/setup-repo.sh <owner/repo>
```

One command onboards a repo: stub workflow, labels, branch protection,
default config. Later,

```sh
setup/doctor.sh <owner/repo>
```

checks the whole arrangement and complains precisely when something drifts.

You'll need a dedicated GitHub App and a Claude Code OAuth token as repo
secrets; setup tells you what's missing. Per-repo behavior lives in
`.smallhours.yml` (models, concurrency caps, which CI workflow gates the
loop). The defaults are meant to be good enough that you rarely open it.

## Going deeper

- [`docs/DESIGN.md`](docs/DESIGN.md): the full design. Both state machines,
  every transition, the edge cases and their rulings.
- [`docs/IMPLEMENTATION-PLAN.md`](docs/IMPLEMENTATION-PLAN.md): build status,
  milestone by milestone.
- [`docs/adr/`](docs/adr/): the hard-to-reverse decisions, and why they went
  the way they did.

---

It's called smallhours because that's when it does its best work — while
you're asleep.
