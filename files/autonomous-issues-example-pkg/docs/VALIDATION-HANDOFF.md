# Validation Handoff — Autonomous Issue → PR → Merge Setup

**To:** Claude Code, running at the root of this repository
**From:** the author of this scaffold
**Mode:** adversarial audit. Do **not** rubber-stamp. Your job is to find what's
broken, unsafe, or based on a wrong assumption — before this runs unattended on a
**public** repo with real secrets. A green `actionlint` run is not a pass.

---

## 0. How to use this doc

Run this from the repo root. Work through every section. For each item, **read
the actual file**, and where possible **prove it** (run a command, query the live
GitHub API, check the real config) rather than reasoning from the YAML alone.
Assume version-dependent facts in this scaffold may be **stale or wrong** and
verify them against current docs. Produce the findings report in §7.

## 1. What this system is supposed to do

A closed loop where a maintainer only (a) files/labels issues and (b) approves +
merges finished PRs. Everything else self-heals:

- Maintainer adds the `agent` label to an issue → Claude implements on
  `agent/issue-<n>` and opens a **draft** PR.
- CI runs. On failure, an auto-fix workflow feeds the failing logs back to Claude,
  which pushes a fix; CI re-runs; capped at 3 attempts, then `human-needed`.
- A scheduled sweep keeps branches current (`BEHIND` → update-branch) and has
  Claude resolve real conflicts (`DIRTY`).
- A state-manager flips the PR **draft ↔ ready** and manages labels, so the PR
  board only ever shows "ready for review" or "still in progress."
- Human approves + merges. That is the only manual gate.

Files: `.github/workflows/{ci,claude-issue-to-pr,auto-fix-ci,keep-prs-green,pr-state-manager}.yml`,
`.github/ISSUE_TEMPLATE/agent-task.yml`, `.github/labels.yml`, `CLAUDE.md`,
`scripts/setup-labels.sh`, `orchestrator/` (optional self-hosted variant),
`docs/SECURITY-PUBLIC-REPO.md`.

## 2. Your mandate

- Adopt a **fail-closed, assume-breach** posture. This automation runs with an
  `ANTHROPIC_API_KEY` and a GitHub App private key, on a repo where anyone can
  open issues and fork.
- Rate every finding **Critical / High / Medium / Low**. Critical = an outsider
  can execute code with secrets, exfiltrate a secret, or merge without human
  approval. High = the loop silently breaks or a maintainer is locked out.
- For each finding: file + line, what's wrong, a concrete exploit or failure
  scenario, and a specific fix (ideally a diff).
- End with a **go / no-go verdict for public-repo deployment**.

## 3. Security audit (highest priority)

3.1 **Trigger gating.** Confirm that on a public repo an anonymous/read user
cannot cause any workflow to run. Trace: who can apply the `agent` label? Does the
issue template auto-apply it (it must NOT)? Does the `authorize` job in
`claude-issue-to-pr.yml` correctly identify the label applier via
`github.event.sender.login`, and does it **fail closed** on API error / unknown
user? Is there a TOCTOU gap between the permission check and the implement job?

3.2 **The `authorize` job's own token.** It calls
`repos/{repo}/collaborators/{actor}/permission` using the default `GITHUB_TOKEN`.
**Verify this call actually succeeds for a legitimate maintainer on a public
repo** — if the default token can't read collaborator permission, the job
fail-closes and locks out the maintainer (a High availability bug). Prove it with
a real `gh api` call.

3.3 **`workflow_run` + forks (pwn-request class).** `auto-fix-ci.yml` and
`pr-state-manager.yml` run on `workflow_run`, which executes with secrets even for
fork PRs. Confirm the `head_repository.full_name == github.repository` guard is
present, correct, and cannot be bypassed (can any field be spoofed by a fork?).
Confirm no untrusted head code is checked out and executed while secrets are in
scope. `keep-prs-green.yml` checks out branches and runs Claude — confirm it can
only ever operate on same-repo, `agent`-labeled PRs and never a fork branch.

3.4 **Tool scope / injection blast radius.** The issue body, PR body, and CI logs
are untrusted text Claude reads. Examine every `--allowedTools` list. In
particular: `auto-fix-ci.yml` allows `Bash(git:*)`, `Bash(npm:*)`, `Bash(node:*)`
while checked out on a branch whose contents can be influenced by an
outside-authored issue. Can `npm` run arbitrary code via a lifecycle script
(`postinstall`)? Can `git` push to an attacker-controlled remote or read other
files? Can `node` execute arbitrary JS in the repo? Assess the realistic
exfiltration/RCE path and whether the scoping is tight enough. Recommend
tightening.

3.5 **Secret hygiene.** Grep the workflows and `CLAUDE.md` for any path that could
echo `ANTHROPIC_API_KEY` or `FIXER_APP_PRIVATE_KEY`. Confirm no debug/verbose
output setting exposes env vars, and that the action's full-output option is off.

3.6 **App token least privilege.** The Fixer App is documented as Contents/Issues/
PRs read-write + Actions read. Is anything over-scoped for what the workflows
actually do? Is `id-token: write` in the workflow `permissions:` actually needed
(create-github-app-token doesn't use OIDC here) — flag unused elevated perms.

3.7 **The human merge gate.** The whole safety story depends on branch protection.
**Query the live repo**: does `main` require a PR, ≥1 approval, and the `CI /
test` status check? Is "require branches up to date" on? Is the Fixer App absent
from any bypass list? Is the org/repo setting "Allow GitHub Actions to create and
approve pull requests" configured such that automation cannot self-approve?
Verify the "a bot cannot approve its own PR" assumption against current GitHub
behavior, not this doc.

## 4. Correctness & event wiring

4.1 **Name matching.** `ci.yml` has `name: CI`. Confirm both `auto-fix-ci.yml` and
`pr-state-manager.yml` reference exactly `workflows: ["CI"]`. A rename silently
kills the loop.

4.2 **Anti-recursion / App token.** Verify the claim that App-token pushes
re-trigger CI while `GITHUB_TOKEN` pushes would not. Confirm the initial PR is
opened with the App token so CI fires on it.

4.3 **Dead guard.** `auto-fix-ci.yml` skips branches starting with `autofix/`, but
fixes are pushed to the original `agent/issue-<n>` branch — **no `autofix/`
branch is ever created**. Confirm this guard is dead code and either remove it or
identify the real recursion risk it was meant to stop (successive fix commits
each re-triggering CI and another fix — is there anything actually stopping an
oscillating fix loop besides the 3-attempt label count?).

4.4 **Does the PR even get created?** The `claude-code-action` does **not** open
PRs by default; this scaffold relies on the *prompt* instructing Claude to run
`gh pr create --draft --label agent`. That is non-deterministic — if the model
doesn't run it, no PR exists and the whole loop never starts. Assess this
reliability risk and recommend a deterministic fallback step (a shell step that
opens the PR if the branch has commits and no PR exists). Verify against current
action docs whether native PR creation now exists.

4.5 **Prompt-dependent labeling.** `keep-prs-green.yml` filters PRs by
`--label agent`, but the PR only gets that label if Claude remembers the
`--label agent` flag in 4.4. If it forgets, the sweep never sees the PR (stale
branches never healed). Same fragility — recommend deterministic labeling.

## 5. State machine & reliability

5.1 **Loop-guard counter.** Attempts are counted via `autofix-attempt-N` labels
that are never removed. If a PR goes green, then a later commit breaks CI again,
the counter doesn't reset and may prematurely hit `human-needed`. Confirm and
propose a reset-on-success rule.

5.2 **`mergeStateStatus` async / UNKNOWN.** This field is computed asynchronously
and is officially undocumented. Confirm the sweep tolerates `UNKNOWN` (does
nothing, retries next cycle) and never makes a wrong decision on a stale value.

5.3 **Sweep concurrency & throughput.** `keep-prs-green.yml` has no `concurrency:`
group and runs every 15 min with a 30-min timeout — can two runs overlap and race
on the same PR? It also resolves only the **first** conflicted PR per run — with
many conflicts, does the backlog ever clear? Assess and recommend.

5.4 **`UNSTABLE` → ready?** `pr-state-manager.yml` marks a PR ready-to-merge on
`CLEAN` *or* `UNSTABLE`. `UNSTABLE` means a non-required check is failing. Is it
correct to present that as "ready to merge"? Judgment call — flag it.

5.5 **Draft/ready thrash.** Trace whether a PR can oscillate between draft and
ready (e.g., auto-fix sends to draft, state-manager sends to ready, they race).
Look for missing ordering guarantees between the `workflow_run`-triggered jobs.

## 6. Version-dependent assumptions to verify LIVE

Do not trust the scaffold on any of these — check current docs
(docs.claude.com / code.claude.com / GitHub docs) and report what's actually true
today:

- `anthropics/claude-code-action@v1` input names used here: `prompt`,
  `claude_args`, `github_token`, `anthropic_api_key`. Still correct? Any renamed
  or removed?
- The model string `claude-sonnet-4-6` — is it a currently valid, available
  model? Replace with the correct current name if not.
- Whether the action enforces an actor-permission check in **automation mode**
  (event + `prompt`, no `@claude` mention). The scaffold assumes it does NOT and
  adds the `authorize` job as belt-and-suspenders. Confirm; if the action does
  enforce it, note the redundancy but keep the explicit guard.
- `gh pr update-branch`, `gh pr ready` / `gh pr ready --undo`, and
  `gh pr view --json mergeStateStatus` — confirm these subcommands/flags exist and
  behave as used in the current `gh`.
- `workflow_run.head_repository.full_name` — confirm it's populated and reliable
  for the fork check.
- Any recent security advisory for `claude-code-action` — confirm the pinned
  version isn't affected and consider pinning to a commit SHA.

## 7. Required output

Produce, in this order:

1. **Findings table**: `# | Severity | File:line | Issue | Exploit/Failure | Fix`.
2. **Suggested diffs** for every Critical and High finding.
3. **Verdict**: GO / NO-GO for public-repo deployment, with the shortlist of
   must-fix items gating a GO.
4. **Residual-risk statement**: what remains unmitigable by config (e.g., prompt
   injection via issue/PR/CI text) and the operational discipline required to run
   this safely.

Do not open a PR or change branch protection yourself. Report; the human decides.

## 8. Known-suspect list (author's own doubts — confirm or refute each)

I already suspect these are wrong or weak. Treat as hypotheses to test, not
settled facts:

- [ ] `authorize` job's `GITHUB_TOKEN` may lack permission to read collaborator
      permission on a public repo → locks out maintainers. (§3.2)
- [ ] `npm`/`node`/`git` in `auto-fix-ci.yml`'s allowedTools is too broad given
      untrusted content on the branch → RCE/exfil path. (§3.4)
- [ ] PR creation and PR labeling are prompt-dependent and will intermittently
      fail, breaking the loop's start and the sweep's visibility. (§4.4, §4.5)
- [ ] The `autofix/` branch guard is dead code; nothing truly bounds an
      oscillating fix loop except the never-reset attempt labels. (§4.3, §5.1)
- [ ] `keep-prs-green.yml` lacks concurrency control and only clears one conflict
      per run → races and backlog. (§5.3)
- [ ] `id-token: write` is unnecessary in several workflows. (§3.6)
- [ ] The model name and possibly some action inputs are stale. (§6)
- [ ] `mergeStateStatus`/`workflow_run.pull_requests[]` emptiness handling has a
      gap for some same-repo cases, not just forks. (§5.2, §3.3)

Report on every checkbox.
