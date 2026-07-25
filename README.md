![smallhours](.github/hero.png)

# smallhours

Coding agents are good now. Watching one work is still a full-time job.

Prompt, watch, nudge, approve.

smallhours is for stepping out of that chair.

## The loop

Write an issue worth doing: goal, acceptance criteria, constraints.

Apply one label: `ready-for-agent`.

Leave.

A sandboxed agent picks the issue up inside your repo's CI, works it on a
branch of its own, and opens a draft PR while you're off doing whatever
you left to do. Red CI, it fixes. Changes requested, it revises. Green,
it waits for you.

You review. You merge. The issue closes; the branch disappears.

The whole job now: write good issues, review good PRs.

## What stays yours

The merge button. Always. Approval is structural; the agent can't grant
one.

When an issue needs a person, it says so, `ready-for-human`, and gets out
of the way.

## Start

```sh
setup/setup-repo.sh <owner/repo>
```

One command. [Getting started](docs/GETTING-STARTED.md) has the rest,
including exactly how far the machine is trusted.

---

It's called smallhours because that's when it does its best work — while
you're asleep.
