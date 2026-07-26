![smallhours](.github/hero.png)

# smallhours

> The best ideas happen away from the keyboard.

Software development shouldn't require constant supervision.

Write good issues. Review good pull requests. Spend the rest of your time
thinking, designing, or simply stepping away. Agents handle the implementation
between those moments.

## The loop

![The smallhours loop. You write the issue, label it ready-for-agent, review, and merge. The agents carry it through agent-working — issue becomes branch becomes a draft PR, fixing CI until green — up to in-review. Requesting changes sends it back to them; work that needs a person exits to ready-for-human.](.github/loop.png)

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

One state label per issue. The board always reflects reality.

If an issue requires human judgment, it's marked `ready-for-human`, and the
agents continue with the next task.

## What stays yours

Architecture.

Judgment.

The merge button.

Agents can build, iterate, and revise, but approval always belongs to you.

## Start

Paste this into Claude Code, in the repo you want to onboard:

> Set up smallhours on this repo: fetch and follow
> https://raw.githubusercontent.com/bcanfield/smallhours/main/docs/GETTING-STARTED.md

Your share is a few clicks and one review — the doc tells your agent
which is which.

Prefer to drive every step yourself — or want the trust boundaries first?
[Getting started](docs/GETTING-STARTED.md) is the same walkthrough,
written for humans too.
