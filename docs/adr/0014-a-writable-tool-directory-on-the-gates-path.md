# 0014 — A writable tool directory on the gate's PATH

**Date:** 2026-08-01
**Status:** Accepted

## Context

[ADR 0012](0012-gate-environment-is-the-runners.md) closed #29 by making the
consumer responsible: the gate's shell is the runner's, so a `verify:` command
must resolve its own entry point. That contract held for one day. Its first
recommended incantation — `corepack pnpm run verify` — resolved its own entry
point and still failed, because `corepack` runs pnpm without putting it on
`PATH`, and mediamtx-connect's `verify` script re-invokes `pnpm` by name. The
gate went red with `command not found: pnpm` from one level down, re-entered
(the missing token was not the command's first word), burned a Sonnet stage on
an environment fault, left a debug script in the tree, and that file — not the
agent's actual work — turned CI red and cost the auto-fix attempt too.

That is three consecutive fixes to the same wound, each correct about the layer
it addressed and each missing the layer beneath. The reading of the Claude Code
sandbox documentation that followed says why.

### The cause was never the shell

The sandbox's default write policy:

> **Default write behavior**: read and write access to the current working
> directory and its subdirectories, plus the session temp directory that
> `$TMPDIR` points to
>
> **Blocked access**: cannot modify files outside the current working directory
> and session temp directory, including shell configuration files such as
> `~/.bashrc` and system binaries in `/bin/`

Every directory on the runner's `PATH` is unwritable to the agent. It cannot
install a binary where a later shell would find it — not in `/usr/local/bin`,
not in `~/.local/bin`, and it cannot write the `~/.bashrc` that would add a
directory of its own. Its only remaining move is a per-invocation launcher, which
is exactly what we observed: `npx pnpm`, resolved out of a hash-keyed cache,
leaving nothing behind.

So ADR 0012's "the agent's toolchain is process-local" was a true description of
the effect and a wrong account of the cause. The toolchain is process-local
**because we forbade every alternative**. And ADR 0011's decision 1 — sourcing
`~/.bashrc` so an installer's `PATH` edit would be visible — was solving a case
the sandbox makes impossible: no agent-bootstrapped installer can write that
file. It was measured working against a fixture that wrote `~/.bashrc` by hand,
which no agent can do.

### What the sandbox does not have

The sandbox has two layers, filesystem and network, and no environment
dimension at all — *"sandboxed Bash commands inherit the parent process
environment by default"*. There is nothing to configure that would make the
agent's `PATH` reach the gate. What is configurable is **where the agent may
write**, and that is the whole problem restated as its own solution.

## Decision

**The toolkit declares one writable directory, on the `PATH` of both the agent
and the gate.**

```
SMALLHOURS_TOOL_PREFIX = ${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smallhours-tools
SMALLHOURS_TOOL_BIN    = $SMALLHOURS_TOOL_PREFIX/bin
```

Four parts:

1. **Created and put on `PATH` before `claude` starts**, in every agent stage.
   Sandboxed commands inherit the parent environment, so the agent's own calls
   see it. Outside the worktree, for the reason the scratch paths already are:
   `git add -A` can never commit it, so it needs no exclusion, cannot pollute a
   pull request, and cannot be mistaken for work by ADR 0009's clean-tree test.
2. **Added to the base sandbox profile's `filesystem.allowWrite`** — the
   toolkit's own entry, with the consumer's list merging on top by union as it
   already does.
3. **Prepended by the gate** to the shell it runs the consumer's command in.
4. **Named in the agent prompts**, with the install flag every ecosystem has:
   `npm i -g --prefix`, `corepack enable --install-directory`, `pip install
   --prefix`, `cargo install --root`, `GOBIN=`, `uv tool install --bin-dir`. Two
   variables rather than one because installers take either a prefix, with `bin`
   appended, or a bin directory — never both.

A consumer then writes `verify: pnpm verify`, or `pytest`, or `cargo test`, and
it works. Because `PATH` is exported rather than merely resolved once, a script
that re-invokes its own package manager by name — the case that broke
`corepack pnpm run verify` — resolves too.

**ADR 0012's contract becomes the fallback rather than the rule.** A command that
resolves its own entry point still works and is still right for a repo that wants
it; it is no longer the price of using the gate at all.

## Consequences

- **The gate executes an agent-authored executable, unsandboxed, if the agent
  puts one in that directory.** This is a second door into an opening ADR 0011
  already recorded: the agent can edit the `package.json` script or `Makefile`
  the gate invokes, and that runs the same way today. Three things bound it:
  the gate *cannot make the loop stricter, only faster* — CI runs the real
  checks and a human merges, so a faked green buys nothing mergeable; the
  directory is private to this mechanism, so nothing else on the machine ever
  executes from it; and the gate **logs the directory's contents on every run**,
  because unlike a `package.json` edit these bytes never appear in a diff.
  That log line is the only review surface this mechanism has, and it is the
  reason it is unconditional rather than only on failure.
- Anthropic's documentation warns against granting writes to *"directories
  containing executables in `$PATH`"*. That warning is about directories other
  contexts already execute from — `~/.local/bin`, `/usr/local/bin` — which is
  why this is a private directory and not one of those.
- A consumer who ignores all of this still gets today's behaviour: an honest
  "the gate could not run", no re-entry spent. The mechanism degrades, it does
  not cliff.
- **Dropping the interactive login shell regresses one case**: a self-hosted
  runner whose toolchain is reachable only through the user's `~/.bashrc`. Never
  observed, and the remedy is one line in that consumer's verify command, but it
  is a real loss and not a free simplification.
- The agent's `PATH` reaching its own Bash calls depends on Claude Code writing
  no shell snapshot in headless runs — measured in ADR 0012, undocumented, and
  the one soft spot in this design. If a future version snapshots and replays
  `PATH`, the agent stops seeing the directory; the **gate** still prepends it
  itself, so the gate keeps working and only the agent's convenience regresses.

## Alternatives

- **Make `~/.local/bin` writable** (already possible today: `allowWrite` is a
  merged list, so any consumer can do this unilaterally). One line, no toolkit
  change. Rejected as the recommendation: it is precisely the directory the
  documentation names as an escalation vector, it is on the `PATH` of everything
  else on the machine, and it makes every consumer solve it separately.
- **A directory inside the worktree.** Writable by default with no sandbox
  change at all. Rejected: it must then be excluded from `git add -A`, from ADR
  0009's clean-tree reasoning, and from the diff — three exclusions where the
  chosen path needs none.
- **Keep ADR 0012's contract and document harder.** Rejected: the contract's own
  first example was wrong in a way no consumer could have predicted, and the
  half that mattered — does the launcher export `PATH` to children — is not a
  thing anyone should have to know.
- **A consumer-declared `setup:` phase.** Rejected again, for ADR 0012's reason:
  it costs the consumer the same line as a good verify command while adding a
  key, a phase, and documentation.

## Payoff trigger

Revisit if the agent is observed installing outside the directory despite the
prompt — that is a prompt problem with a measurable signal, since the gate logs
the directory's contents on every run. Revisit the security posture if the gate
ever becomes a merge gate rather than an advisory one, because the argument
above rests entirely on it not being one.
