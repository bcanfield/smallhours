![smallhours](.github/hero.png)

# smallhours

> The best ideas happen away from the keyboard.

Software development shouldn't require constant supervision.

Write good issues. Review good pull requests. Spend the rest of your time
thinking, designing, or simply stepping away. Agents handle the implementation
between those moments.

## The loop

Fill the board with issues worth solving. Label what's ready:

`ready-for-agent`

Then leave.

Sandboxed agents continuously work the queue inside your repository's CI.
Each issue becomes its own branch. Each branch becomes a draft pull request.

If CI fails, they fix it.
If changes are requested, they revise it.
When everything is green, they wait.

You come back to finished work—not an endless stream of notifications.

Review. Merge. Repeat.

## The board

```
ready-for-agent → agent-working → in-review → closed
```

One state label per issue. The board always reflects reality.

If an issue requires human judgment, it's marked `ready-for-human`, and the
agents continue with the next task.

## What stays yours

Architecture.

Judgment.

The merge button.

Agents can build, iterate, and revise, but approval always belongs to you.

## Start

Fifteen minutes: an App, a token, one command, one canary.

```sh
setup/create-app.sh <owner/repo>    # your Fixer App + its two secrets, one click to install
claude setup-token                  # → gh secret set CLAUDE_CODE_OAUTH_TOKEN
setup/setup-repo.sh <owner/repo>    # labels, stub, config, protection — ends with a checklist
```

Or delegate even this — paste into Claude Code and keep only the clicks
that are structurally yours:

> Set up smallhours on `<owner/repo>` for me: clone
> https://github.com/bcanfield/smallhours, read `docs/GETTING-STARTED.md`,
> and follow the walkthrough under its agent contract — do everything you
> can yourself, hand me only what the contract marks as mine, and finish
> with a clean `setup/doctor.sh` and the canary in my review queue.

Then label one trivial canary issue `ready-for-agent` and watch it travel
the whole loop.

See [Getting started](docs/GETTING-STARTED.md) for the step-by-step
walkthrough, trust boundaries, and how autonomous execution is kept
contained.
