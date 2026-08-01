# Getting started

Everything you need to onboard a repo and understand what the system will
and won't do on its own. The [README](../README.md) is the short version;
this is the operator's version. The walkthrough takes about 15 minutes and
ends with a merged agent PR. Follow it yourself, or hand it to a coding
agent (next section) and your share shrinks to a few clicks and one review.

## Let your agent set it up

The walkthrough is written to be followed by you **or** by a coding agent
acting for you — the same numbered steps, the same remedies. To delegate
it, paste the two-line prompt from the README's
[Start](../README.md#start) section into Claude Code (or any agent with
shell access) inside the repo you're onboarding, on the machine where
`gh` and `claude` are authed. Everything the agent needs beyond that
prompt is below.

"This repo" is whatever the working directory's git remote says — an
agent that can't resolve a single `<owner/repo>` from it should ask,
never guess.

### The agent contract

If you are an agent following this document: your goal is a clean
`setup/doctor.sh` and the canary PR waiting in the human's review queue,
touching the human only at the four reserved moments below. Report back
what the contract marks as theirs; do everything else yourself. The
split is:

**Yours: everything scriptable.** The clone (step 1) — into a temp or
sibling directory, never inside the consumer repo's working tree;
`create-app.sh` (step 2); `setup-repo.sh` (step 5) — after step 3's
secret exists, since its checklist fails without it (both scripts are
idempotent, so re-running is always safe); creating the canary and
labeling it `ready-for-agent`
only once the stub is on the default branch (after the onboarding PR
merges, when one opens); and diagnosing stalls against step 6's numbered
list by polling short `gh` calls — never a long sleep. `setup/doctor.sh`
verifies each step before the next: exit 0 is clean, ⚠ lines are
acceptable, and the App-install check can only warn until the first
successful run.

**The human's: the four moments reserved for them.**

1. **The Create App click** (step 2). `create-app.sh` opens their
   browser, then blocks on a localhost listener until the click
   round-trips — say so before you run it, and give it a generous
   timeout. Without a TTY it won't pause for the install click; the
   deep link is in its log, and `doctor.sh` verifies. No browser
   reachable from your session (remote/headless)? The flow can't
   complete — walk them through the manual fallback instead.
2. **Minting the token** (step 3). Never run `claude setup-token`
   yourself — the token would land in your transcript. Have them run
   both step-3 commands in their own terminal. An interrupted
   `gh secret set` can store an *empty* secret that passes every
   presence check, so the fix for any doubt is re-running it — never
   showing you the value. Confirm with `gh secret list` / `doctor.sh`.
3. **The install click** (step 4).
4. **Review and merge** — the onboarding PR (when one opens) and the
   canary PR. Branch protection makes approval structurally theirs;
   never work around it, and never pass `--skip-protection` unasked.

Secret material never belongs on a command line or in your context: move
it only by redirection (`gh secret set … < file.pem`) or in the human's
own terminal. The App ID and slug are not secrets. End by reporting the
setup checklist, the doctor output, and where the canary stands.

## Prerequisites

Have these before starting:

- **A repo with a CI workflow.** The loop keys off your existing CI;
  green/red is one of the two signals that drive everything. A workflow
  named `ci` in any casing is auto-detected and wired with its exact
  display name; anything else, you'll pass the exact name in step 5.
- **A Claude subscription** (Pro/Max). The agent runs on a subscription
  OAuth token — never a metered API key.
- **Tools:** `gh` (authed, `repo` + `workflow` scopes), `jq`, `openssl`,
  `curl`, `nc`. And `claude` locally, for minting the token in step 3.

## The walkthrough

### 1. Clone the toolkit

```sh
git clone https://github.com/bcanfield/smallhours && cd smallhours
```

Nothing installs; every command below runs from this clone. Your repo gets
only a thin workflow stub and a config file (step 5).

### 2. Create the Fixer App

The Fixer is a GitHub App **you own** — the identity every automation action
runs under, so the audit trail always distinguishes machine actions from
yours. One per maintainer; it is never hosted centrally.

```sh
setup/create-app.sh <owner/repo>        # add --org <org> for an org-owned repo
```

Your browser opens a pre-filled registration (name, the four permissions,
webhook off) — click **Create GitHub App** and return to the terminal. The
script then sets the two App secrets on your repo, saves the private key
under `~/.smallhours/`, and walks you to the install click (step 4).

The three secrets, for reference — where each comes from and how to set it
by hand:

| Secret | What it is | Provenance | Set it yourself |
|---|---|---|---|
| `AGENT_APP_ID` | the App's numeric ID | the App's settings page (top) | `gh secret set AGENT_APP_ID --repo <owner/repo> --body <id>` |
| `AGENT_APP_PRIVATE_KEY` | the App's PEM private key | App settings → Private keys → *Generate* (downloads a `.pem`) | `gh secret set AGENT_APP_PRIVATE_KEY --repo <owner/repo> < <file>.pem` |
| `CLAUDE_CODE_OAUTH_TOKEN` | your Claude subscription OAuth token | `claude setup-token` (step 3) | `gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner/repo>` then paste |

#### Manual fallback: register the App in the UI

If `create-app.sh` can't run (no browser, no free port), register by hand:

1. <https://github.com/settings/apps/new> (org-owned:
   `github.com/organizations/<org>/settings/apps/new`).
2. Name it anything (e.g. `smallhours-fixer-<you>`); any homepage URL.
3. **Under Webhook, uncheck "Active"** — this is the classic tripwire: left
   checked, the form demands a webhook URL you don't have. The loop is
   Actions-driven; no webhook is ever needed.
4. Repository permissions: **Contents: Read and write · Issues: Read and
   write · Pull requests: Read and write · Actions: Read-only.** (Issues
   write also covers native issue dependencies — there is no separate
   dependencies permission.)
5. "Only on this account" → **Create GitHub App**.
6. Note the **App ID**, generate a **private key**, and set both secrets
   with the commands in the table above.

### 3. Set the Claude token

```sh
claude setup-token
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner/repo>   # paste the token
```

This is the subscription token the agent runs on — spend rides your Claude
plan and is bounded per run by `max_turns`. If the subscription quota runs
out mid-run, the loop gives up cleanly (`ready-for-human`), never retries in
a loop.

### 4. Install the App on your repo

Installation is the one step GitHub reserves for a human click; a script
cannot do it for you. `create-app.sh` opens it; the link is always:

```
https://github.com/apps/<your-app-slug>/installations/new
```

Select your repo and confirm. A missed install is the classic silent
failure — nothing happens at first trigger — so `setup/doctor.sh` checks
for it (see step 6's diagnostics).

### 5. Onboard the repo

```sh
setup/setup-repo.sh <owner/repo> [--ci-workflow NAME] [--required-checks a,b] [--skip-protection] [--dry-run]
```

Runs with your own `gh` auth and does, in order: verify the three secrets,
create the label vocabulary, land the stub workflow and a default
`.smallhours.yml` wired to your CI name (via PR if your default branch
requires PRs), enable secret-scanning push protection and branch-deletion on
merge, and set branch protection unless the branch is already covered by a
ruleset. Pass `--ci-workflow "<name>"` when your CI workflow isn't named
`ci`.

Setup always ends with a met/unmet checklist — every ✗/⚠ carries its
remedy — and the onboarding PR (when one is opened) mirrors the same
checklist in its body. Afterwards, and any time something feels off:

```sh
setup/doctor.sh <owner/repo>
```

re-checks every precondition plus stub version drift, and exits nonzero on
any failure, so it is safe to run in a scheduled audit.

### 6. First run: the canary

Before feeding it real work, run one deliberately trivial issue end to end.
The canary exercises every canonical transition once, so **where it stalls
tells you exactly what is miswired**.

```sh
gh issue create --repo <owner/repo> \
  --title "Canary: add CANARY.md" \
  --label enhancement \
  --body 'Add a file `CANARY.md` at the repo root containing exactly one line:

    smallhours canary

Acceptance criteria:
- `CANARY.md` exists with that single line.
- Nothing else changes.'
```

Then pull the trigger (this is also how every real issue starts):

```sh
gh issue edit <n> --repo <owner/repo> --add-label ready-for-agent
```

What you should see, in order — and what it means when you don't:

1. **An `agent-loop` run appears** under the repo's Actions tab within
   about a minute of labeling. *Missing?* The stub isn't on the default
   branch — merge the onboarding PR. Run failing in its first step ("app
   token")? The Fixer App isn't installed (step 4) or its secrets are wrong
   — `setup/doctor.sh` pinpoints which.
2. **The issue flips to `agent-working`.** *Missing?* The dispatcher didn't
   promote it: label vocabulary drift (doctor), or `max_concurrent` slots
   are full.
3. **A draft PR appears** from branch `agent/issue-<n>`, labeled `agent`.
   *Missing?* Open the implement run's log — a failed run posts its
   give-up on the issue and moves it to `ready-for-human`.
4. **Your CI runs on the draft PR.** *Missing?* The `ci_workflow` name in
   `.smallhours.yml` doesn't match your workflow's display name — fix it
   and push, or re-run setup with `--ci-workflow`.
5. **On green, the PR flips ready** (label `ready-to-merge`) **and the
   issue moves to `in-review`** — your queue. *Missing?* The sweep re-check
   runs on the next tick (≤15 min); still stuck after that, check the
   `workflow_run` leg in the agent-loop run list.
6. **You approve and merge.** The agent never can — branch protection makes
   your review structurally required.
7. **The branch is auto-deleted and the issue closes.** *Branch lingering?*
   `gh repo edit <owner/repo> --delete-branch-on-merge`.

A green canary means every wire is connected: triggers, App identity, CI
gate, state labels, protection. From here, grill real issues and label them
`ready-for-agent`.

**One class to keep out of that queue: anything whose work edits
`.github/workflows/`.** The App is deliberately not granted GitHub's separate
`workflows` permission, so a push touching a workflow file is rejected
server-side no matter how good the change is — the agent does the work, the push
bounces, and the issue hands back to you having spent a full turn. The agent is
told to stop early when it can see the requirement, but it only sees what the
issue says; you can see what the work will touch. Make those changes by hand.
See [ADR 0013](adr/0013-workflow-files-stay-human.md).

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
- `sandbox`: widen the sandbox the agent runs under — lists only, appended to a
  hardened profile. See "Letting the agent check its own work".
- `verify` / `verify_reentries`: the command the agent's work is checked against
  before a PR opens, and how many times a failure sends it back to the agent.
- `labels`: map canonical label names to your repo's existing strings.
- `conventional_title_types`: set this if your repo enforces conventional
  commits. A PR is titled from its issue title, and on a squash-merging repo
  that title becomes the release commit — so an unprefixed one fails your own
  format check and costs an auto-fix attempt to correct. Map your issue labels
  to commit types and the prefix comes for free:

  ```yaml
  conventional_title_types:
    bug: fix
    enhancement: feat
  ```

  Leave it out and titles pass through verbatim, exactly as before. An issue
  whose labels don't map is also left verbatim — smallhours will not guess a
  type, because guessing `chore:` would drop a feature out of your next release.

The defaults are meant to be good enough that you rarely open this file.

## Letting the agent check its own work

Nothing is installed in the agent's environment. On a repo with dependencies that
means the agent writes code it cannot compile or test, and CI is the first thing
that ever runs its work — minutes later, and at the cost of one of your
`attempt_cap` auto-fix attempts. Two keys close that gap. Both are optional; a
repo that sets neither behaves exactly as it did before they existed.

**1. Let it install.** `npm_allowed: true` opens your registry, but egress alone
is not enough: the sandbox permits writes to the working directory and `$TMPDIR`
only, and a package store lives outside both. Add the store paths:

```yaml
npm_allowed: true
sandbox:
  filesystem:
    allowWrite: ["~/.local/share/pnpm", "~/.npm", "~/.cache"]
```

Those paths are ecosystem-specific — `~/.cargo`, `~/.cache/pip`, `~/go/pkg` — so
smallhours does not guess them. Everything under `sandbox:` is a **list**, and
lists are appended to a hardened profile: you can add paths, hosts and commands,
but the protections themselves (`allowUnsandboxedCommands`, `filesystem.disabled`,
`allowManagedDomainsOnly`, the Unix-socket keys, …) belong to smallhours. Set one
and it is ignored with a warning. Full key reference:
[Claude Code sandbox settings](https://code.claude.com/docs/en/settings#sandbox-settings).

Then tell the agent to install, in your repo's `AGENTS.md` or `CLAUDE.md`. It
reads those; it will not guess your package manager.

**Where a tool it installs has to land.** Everything on the runner's `PATH` is
read-only inside the sandbox — including `~/.bashrc`, so the agent cannot even
add a directory of its own. smallhours gives it exactly one writable directory on
`PATH`, `$SMALLHOURS_TOOL_BIN`, and the agent's prompts point at it with the flag
every installer has (`--prefix`, `--root`, `--install-directory`, `GOBIN`). A
tool that lands there is visible to the check below; one reached any other way —
a per-command launcher like `npx`, a scratch directory — disappears with the
process that ran it (ADR 0014).

**2. Gate the push.** `verify` is any shell command, run after the agent finishes
and before the pull request opens:

```yaml
verify: pnpm verify
verify_reentries: 2
```

If it fails the agent is **re-entered** — resumed with the command's output — up
to `verify_reentries` times. A lint or type error caught here costs seconds
instead of a CI round trip and an auto-fix attempt.

The gate can never stall an issue. Still failing after its re-entries, the branch
is pushed anyway and the pull request says so, carrying the command, its exit
status and the tail of its output. CI stays exactly the backstop it already was.

Point `verify` at checks that are **fast and need no services** — linters, type
checks, unit tests. The agent has no Docker, no browsers, and cannot bind a local
port, so browser and integration suites belong in CI rather than in the gate.

The command runs with `$SMALLHOURS_TOOL_BIN` on `PATH`, so whatever the agent
installed there — `pnpm`, `pytest`, `cargo`, a linter — resolves by bare name,
and so does a script of yours that re-invokes its own package manager. Nothing
else the agent did survives: a virtualenv activated inside one command, a tool
fetched per invocation, an environment variable it exported.

If your command's entry point comes from somewhere else entirely, make it
self-contained — a committed script (`./scripts/verify.sh`), a wrapper the repo
ships (`./mvnw`, `./gradlew`), or an absolute path. That is the fallback, not the
rule it once was.

If your command's own executable does not resolve, smallhours does **not** hand
the error to the agent to "fix" — it says on the pull request that the gate could
not run and that nothing was checked, because no amount of editing your code
would make that command start, and the run log records what the gate could and
could not see. See [ADR 0012](adr/0012-gate-environment-is-the-runners.md).

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
  the Claude API, and whatever you add via `egress_extra_domains`, `npm_allowed`
  or `sandbox.network.allowedDomains`. A prompt-injected issue has very few
  places to send anything — though every host you add is one more, so add the
  registry you need rather than the ones you might.
- The sandbox's protections are smallhours' to set, not your repo's. `sandbox:`
  can only widen lists, so a compromised or careless change to `.smallhours.yml`
  cannot turn isolation off. It is also rendered before the agent starts, so a
  widening the agent writes itself only reaches a pull request, never the run
  that wrote it.
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
