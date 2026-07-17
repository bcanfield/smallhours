# Setup

One-time setup. Budget ~20 minutes. Steps 1–3 are the ones that actually make
the loop work; skipping the GitHub App (step 2) is the most common reason people
find CI never re-runs on the bot's commits.

## 1. Install the Claude GitHub App + API key

- From a checkout of this repo, run `/install-github-app` inside Claude Code, **or**
  install the app manually at <https://github.com/apps/claude> with Contents,
  Issues, and Pull requests set to **Read & write**.
- Add your Anthropic API key as a repo secret named `ANTHROPIC_API_KEY`
  (Settings → Secrets and variables → Actions → New repository secret).
  Set a spend cap on the key so an unattended loop can't run away.

## 2. Create the "Fixer" GitHub App (critical)

Why: commits/PRs made with the default `GITHUB_TOKEN` do **not** trigger other
workflows (GitHub's anti-recursion safeguard). If Claude pushes with that token,
CI never re-runs, so a PR can never go green → the loop stalls. A separate App is
a distinct identity whose pushes DO trigger CI.

1. <https://github.com/settings/apps> → **New GitHub App**.
2. Permissions (Repository): Contents = R/W, Issues = R/W, Pull requests = R/W,
   Actions = Read.
3. Create it, note the **App ID**, generate a **private key** (downloads a .pem).
4. **Install** the app on this repo.
5. In the repo: add a **variable** `FIXER_APP_ID` (the App ID) and a **secret**
   `FIXER_APP_PRIVATE_KEY` (paste the entire .pem contents).

Every workflow here mints a short-lived token from this App via
`actions/create-github-app-token@v2`.

## 3. Branch protection (preserves your human merge gate)

Settings → Branches (or Rules → Rulesets) on `main`:

- ✅ Require a pull request before merging → **Require 1 approval**.
- ✅ Require status checks to pass → select the **CI / test** check.
- ✅ Require branches to be up to date before merging (this is what produces the
  `BEHIND` state that keep-prs-green.yml resolves).
- ❌ Do **not** add the Fixer App to any bypass list.

Because a bot can't approve its own PR, "require 1 approval" makes your
approve+merge click structurally required — no amount of automation can
self-merge. That's the safety property you want.

> Optional, more autonomous: drop "require approval" to 0 on a low-risk repo and
> enable auto-merge if you ever want fully hands-off merging. Not recommended
> until you've watched the loop behave for a few dozen PRs.

## 4. Labels + issue template

```bash
gh auth login
./scripts/setup-labels.sh          # creates the label vocabulary
```

The issue template in `.github/ISSUE_TEMPLATE/agent-task.yml` auto-applies the
`agent` label, which is the trigger.

## 5. Try it

1. Open a new issue with the "Agent task" template. Example goal:
   *"Add a `median(numbers)` function to src/stats.js with tests."*
2. Submit. `claude-issue-to-pr.yml` fires, Claude implements on
   `agent/issue-<n>`, and opens a **draft** PR.
3. CI runs. If it fails, `auto-fix-ci.yml` repairs it (up to 3 tries). If the
   branch drifts or conflicts, `keep-prs-green.yml` handles it.
4. When green + clean, `pr-state-manager.yml` marks the PR **ready** and labels
   it `ready-to-merge`.
5. You review, approve, and merge. Done.

## Tuning knobs

- `--max-turns` in each workflow — lower to cap cost per run.
- `--model` — Sonnet for routine work; escalate to a stronger model only for
  gnarly multi-file failures. **Verify current model names** against
  <https://docs.claude.com> before pinning.
- Loop guard threshold — change `-ge 3` in `auto-fix-ci.yml`.
- Sweep cadence — the cron in `keep-prs-green.yml`.

## Verify the model / action versions

Claude Code and its GitHub Action change often. Before relying on this, confirm:
`anthropics/claude-code-action@v1` inputs (`prompt`, `claude_args`), the current
model string, and any new options — see code.claude.com/docs and the action's
`examples/` directory.
