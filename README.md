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

Paste this into Claude Code, in the repo you want to onboard:

> Set up smallhours on this repo for me: follow the walkthrough in
> https://github.com/bcanfield/smallhours/blob/main/docs/GETTING-STARTED.md
> under its agent contract — do everything you can yourself, hand me only
> what the contract marks as mine, and finish with a clean
> `setup/doctor.sh` and the canary in my review queue.

Your share is a few clicks and one review: creating and installing the
Fixer App, minting your Claude token, approving the canary PR.

Prefer to drive every step yourself — or want the trust boundaries first?
[Getting started](docs/GETTING-STARTED.md) is the full walkthrough.
