![smallhours](.github/hero.png)

# smallhours

It does its best work while you're asleep.

The whole job now: write good issues, review good PRs. Agents handle
everything between.

## The loop

Fill the board with issues worth doing. Label what's ready:
`ready-for-agent`.

Leave.

Sandboxed agents work the queue inside your repo's CI, each issue on its
own branch, each branch a draft PR, while you're off doing whatever you
left to do. Red CI, they fix. Changes requested, they revise. Green, they
wait.

You review. You merge. Issues close; branches disappear.

## The board

```
ready-for-agent → agent-working → in-review → closed
```

One state label per issue, always. The board never lies.

When an issue needs a person, it says so, `ready-for-human`, and the
agents move on.

## What stays yours

The merge button. Always. Agents can't grant approvals.

## Start

```sh
setup/setup-repo.sh <owner/repo>
```

[Getting started](docs/GETTING-STARTED.md) has the rest, including exactly
how far the machine is trusted.
