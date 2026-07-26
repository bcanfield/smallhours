# Getting started

Everything you need to onboard a repo and understand what the system will
and won't do on its own. The [README](../README.md) is the short version;
this is the operator's version. The walkthrough takes about 15 minutes and
ends with a merged agent PR. Follow it yourself, or hand it to a coding
agent (next section) and your share shrinks to a few clicks and one review.

## Let your agent set it up

The walkthrough is written to be followed by you **or** by a coding agent
acting for you — the same numbered steps, the same remedies. To delegate
it, paste this into Claude Code (or any agent with shell access) inside
the repo you're onboarding, on the machine where `gh` and `claude` are
authed:

> Set up smallhours on this repo for me: follow the walkthrough in
> https://github.com/bcanfield/smallhours/blob/main/docs/GETTING-STARTED.md
> under its agent contract — do everything you can yourself, hand me only
> what the contract marks as mine, and finish with a clean
> `setup/doctor.sh` and the canary in my review queue.

"This repo" is whatever the working directory's git remote says — an
agent that can't resolve a single `<owner/repo>` from it should ask,
never guess.

### The agent contract

If you are an agent following this document, the split is:

**Yours: everything scriptable.** The clone (step 1); `create-app.sh`
(step 2); `setup-repo.sh` (step 5) — after step 3's secret exists, since
its checklist fails without it (both scripts are idempotent, so re-running
is always safe); creating the canary and labeling it `ready-for-agent`
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
