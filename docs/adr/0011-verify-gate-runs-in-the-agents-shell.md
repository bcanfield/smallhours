# 0011 — The verify gate runs in the agent's shell, and says so when it cannot run at all

**Date:** 2026-07-31
**Status:** Accepted. Decision 1's reach is bounded by
[ADR 0012](0012-gate-environment-is-the-runners.md), which found that a toolchain
the agent never wrote to disk is beyond any shell — the decisions below stand
unchanged.

## Context

The first live run of the verify gate (mediamtx-connect#300, a canary). The
agent installed dependencies, ran the suite, wrote tests and updated the
lockfile — all successfully. Then the gate came back:

```
$ pnpm verify
exited 127

bash: line 1: pnpm: command not found
```

Nothing was wrong with the repo. The gate handed that error to the agent as if
it were a code defect, and the re-entry spent **31 turns and $2.22** trying to
fix code that was already correct before hitting `max_turns` and giving up. The
"a red gate never stalls an issue" guarantee held — the branch pushed, the PR
carried the report — but the run was a write-off.

`verify_gate` ran the consumer's command as `bash -c "$cmd"`: a **non-interactive,
non-login** shell, which sources no startup file at all. Claude Code's own Bash
tool runs commands through a shell initialised from the user's profile, so the
agent saw a `PATH` the gate did not.

The consequence generalises well past pnpm. ADR 0008 deliberately chose "let the
agent install its own dependencies" over a setup phase, so **any toolchain the
agent bootstraps for itself is invisible to the gate** — this is the common
case, not an edge one.

### What the shell actually does

The obvious one-word fix — `bash -lc`, a login shell, which is what a developer
typing the command gets — **resolves nothing**, and it took measurement to see
why. Ubuntu's stock `~/.bashrc` opens with

```sh
case $- in *i*) ;; *) return;; esac
```

and every installer (pnpm, bun, cargo, nvm, pyenv, sdkman) appends *below* that
guard. A non-interactive shell returns at line one and reads none of it.

Nor is `-lic` a superset of `-ic`. Bash reads `~/.bashrc` for an interactive
**non-login** shell, and `/etc/profile` plus the first of `~/.bash_profile`,
`~/.bash_login`, `~/.profile` for an interactive **login** shell — never both.
Ubuntu's stock `~/.profile` sources `~/.bashrc`; any file that shadows
`~/.profile` silently severs that chain.

Measured on `ubuntu-24.04` by the `gate-environment` job, against a toolchain
bootstrapped the way an agent bootstraps one:

| form | PATH entry from `~/.bashrc` | shell function from `~/.bashrc` | PATH entry inherited from the job env |
|---|---|---|---|
| `bash -c` | no | no | yes |
| `bash -lc` | **no** | **no** | — |
| `bash -ic` | yes | yes | — |
| `bash -lic` | **no** | **no** | — |
| `bash -lic` + explicit `. ~/.bashrc` | yes | yes | yes |

The last column is the hazard `-l` brings: Debian and Ubuntu's `/etc/profile`
**assigns** `PATH` rather than extending it, so a login shell can drop what the
job environment put there — including the `$HOME/.local/bin` entry
`claude-run.sh` adds for `claude` itself, and any `npx`/`corepack` the gate's own
documented remedy depends on. It survives on this image; the job asserts it,
because nothing but a measurement can say that of the next image.

The fourth row is the one to remember. **The hosted runner's user has a
`~/.bash_profile`**, so the login shell never reaches `~/.profile` and never
reaches `~/.bashrc` — bare `-lic` resolves exactly nothing there. Only the last
row works, and it is the only reason this ADR's fix does anything at all. This
was caught by the job on its first run, on a build that would otherwise have
shipped looking correct.

### One more thing `-i` drags in

An interactive shell sources `/etc/bash.bashrc`, where Debian and Ubuntu define
`command_not_found_handle`. A missing command then prints the distro's
apt-suggestion text instead of bash's own `…: command not found` — so the
classification in decision 2, which parses exactly that one message, stopped
recognising it. Same first run, same job: the gate re-entered on an unresolvable
command, which is precisely the waste it was written to prevent.

The handler is unset in the gate's shell. It is a nicety for humans at a prompt;
in a CI gate it costs an apt-database query and makes the one message this gate
must parse depend on which distro the runner happens to be.

## Decision

### 1. The gate initialises the shell fully

The consumer's command runs under `bash -lic`, which additionally sources
`~/.bashrc` explicitly. Three flags and one source, because no single form
covers every arrangement — see the table above. Re-sourcing `~/.bashrc` when the
profile chain already did is safe; rc files guard their own `PATH` edits.

This is **runtime-agnostic by construction**. The toolkit knows the name of no
package manager: exported variables (`JAVA_HOME`, `VIRTUAL_ENV`, `GOPATH`,
`CARGO_HOME`) and shell functions (`nvm`, `sdkman`, `pyenv`, `asdf`) arrive by
the same door. A fix that captured `PATH` alone would have quietly re-specialised
the gate to toolchains that only prepend a directory.

The command travels to the shell in an environment variable and is `eval`'d,
rather than being interpolated into the `-c` string. An interactive shell
history-expands what it parses, so a `!` anywhere in a consumer's command would
otherwise be mangled before it ran. `set +H` covers the `eval`.

An interactive login shell brackets the command with chatter of its own — a
job-control complaint about the missing tty on the way in, `logout` on the way
out. Both are stripped, **by position only**: leading job-control lines and a
trailing `logout`. The same strings in the middle could only have come from the
consumer's command and survive. Getting this wrong leniently would also mask a
silent failure — a command that exits non-zero printing nothing must leave an
empty log, or the report says "here is the output" and shows bash talking to
itself.

### 2. "The gate could not run" is a different message from "your code is broken"

When the command exits 127 **and the executable bash could not find is the
command's own first token**, the gate never started. Nothing about the agent's
work has been checked.

In that case the gate does not re-enter. Re-entry cannot succeed — the agent has
no way to change the shell the gate runs in — and one costs a full Claude stage,
which is exactly the 31 turns and $2.22 above.

The test is deliberately narrow. A 127 from *inside* the command — the
consumer's `make test` shelling out to a tool the agent should have installed —
still re-enters, because there the agent can fix it. A leading `VAR=x` or a
builtin first token makes the comparison miss and costs a re-entry we would have
spent anyway: the conservative direction.

The pull request gets its own notice, separate from the red-gate warning, saying
plainly that the branch was not checked and naming the command that did not
resolve. The remedy is the maintainer's, not the agent's — only they can change
the `verify:` line — and the PR is the surface they read. It names no package
manager: the fix has the same shape in every ecosystem, and a node-flavoured
example would read as inapplicable to everyone else.

The report file carries a marker line (`red` or `could-not-run <name>`) so
`open-pr.sh` can tell the two apart across the process boundary.

### 3. The runner's own behaviour is a standing check, not a one-off measurement

`tests.yml` gains a `gate-environment` job that bootstraps a toolchain the way an
agent would — a `PATH` entry *and* a shell function, appended below `~/.bashrc`'s
guard — and asserts the gate sees both, and that an unresolvable command is
classified rather than re-entered.

The unit suites cannot cover this: they are pure logic by contract, and they
prove the gate against fixtures we wrote. Whether a *real runner image's*
startup files defeat us is a fact only a runner can answer.

This is not hypothetical. **Both defects in the "what the shell actually does"
section above were found by this job on its first run**, on a change whose unit
suites were green and whose author had measured the behaviour by hand on a
different OS. The runner shipped a `~/.bash_profile` and a
`command_not_found_handle`; the development machine had neither. Without the
job, this ADR's fix would have merged, resolved nothing, and been discovered by
a consumer one wasted agent run at a time — the exact failure it exists to fix.

Everything the job asserts is also mirrored in `tests/test-verify.sh` against
fixtures reproducing the runner's arrangement, so the regression is caught
locally too; the job is what proves the fixtures still match reality.

## Consequences

- A consumer whose package manager is not on the default `PATH` gets a green
  gate without special-casing their `verify:` command.
- The worst case is now an honest first-attempt message instead of a burned
  stage. **Decision 2 is the backstop for decision 1 being incomplete**: for any
  toolchain no shell trick can reach — a venv activated inside a single agent
  Bash call, a container, a project-local `node_modules/.bin` — the gate says so
  on the first attempt rather than spending an agent on it.
- **The gate now executes the runner user's startup files.** A consumer grants
  `sandbox.filesystem.allowWrite` for their package store, so an agent may be
  able to write under `$HOME`; a written `~/.bashrc` is then code the gate runs
  outside the sandbox. This adds **no new capability class**: the gate already
  executes agent-editable code unsandboxed by design — the agent can edit the
  `package.json` script or `Makefile` the verify command invokes, and that runs
  the same way today. It is a second door into an opening the risk register
  already carries as residual (prompt injection via issue text, ADR 0001). No
  new control; recorded so nobody rediscovers it as a surprise.
- Interactive-shell startup costs a few tens of milliseconds per gate run, and
  any side effect a consumer's rc files have now happens on every run.
- A consumer whose `verify:` first token is a shell builtin or preceded by an
  environment assignment gets the old behaviour on a 127. No regression, just no
  improvement.
- One more thing `open-pr.sh` has to say precisely, and a report-file format that
  two scripts must agree on.

## Alternatives

- **`bash -lc`** (the issue's own first option). One word, and it is what a
  developer running the command gets. Rejected on measurement: it resolves
  nothing, because `~/.bashrc` returns above where installers write. Recorded
  here because it is the fix everyone will propose next.
- **Snapshot `PATH` from a login+interactive shell and replay it.** Keeps the
  noisy interactive startup off to the side. Rejected as too narrow — it drops
  `JAVA_HOME`, `VIRTUAL_ENV`, `GOPATH` and every function-based version manager,
  re-specialising a fix that should be language-neutral.
- **Source Claude Code's shell snapshot** (`~/.claude/shell-snapshots/`). By
  definition byte-identical to the agent's environment, whatever the runtime —
  the most faithful answer available. Rejected for depending on a Claude Code
  internal whose path and format no contract promises. Reconsider if that
  location ever becomes documented.
- **Treat any exit 127 as an environment fault.** Simplest rule, no token
  comparison. Rejected: it gives up on genuinely fixable cases where a tool
  nested inside the consumer's own script is the agent's omission.
- **Keep re-entering, but warn the agent the failure may be environmental.**
  Cannot regress a fixable case and is the smallest diff. Rejected because it
  still spends the stage — it bounds the 31 turns rather than avoiding them.
- **Document the gate's bare shell in `GETTING-STARTED.md` and change nothing.**
  Honest and cheap. Rejected: it leaves a trap whose first trigger costs a run,
  and every consumer discovers it independently.

## Payoff trigger

Revisit decision 1 if the `gate-environment` job ever goes red — that is the
runner image changing under us, and the table above is the measurement to redo.
Revisit decision 2's first-token test if a consumer is ever observed losing a
fixable 127 to it. Revisit the security note if the sandbox's `allowWrite`
posture changes such that the gate stops being able to execute agent-edited
code, at which point rc files would become a genuinely new opening.
