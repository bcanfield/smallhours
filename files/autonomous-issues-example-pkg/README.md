# Autonomous Issues → PRs → Merge with Claude Code

An example repo showing a **self-healing** workflow where you only ever:

1. **Create issues**, and
2. **Approve + merge** finished PRs.

Everything in between — implementation, opening the PR, fixing failed CI,
resolving merge conflicts, keeping branches current, and flipping the PR between
"in progress" and "ready" — runs itself. When you look at your PR board, every PR
is either **ready for your review** or a **draft that's still being worked**.
There is no ambiguous middle state.

## The loop

```
  you file an issue  (label: agent)
          │
          ▼
  claude-issue-to-pr.yml ── Claude implements on agent/issue-<n>, opens a DRAFT PR
          │
          ▼
        ci.yml  (tests + lint)
          │
   ┌──────┼───────────────┬────────────────────────────┐
   │ fail │               │ behind / conflict          │ pass + clean
   ▼      │               ▼                            ▼
 auto-fix-ci.yml     keep-prs-green.yml         pr-state-manager.yml
 reads logs,         update-branch (behind)     marks PR READY,
 Claude pushes fix,  Claude resolves (dirty)    labels ready-to-merge
 CI re-runs,                                        │
 up to 3 tries                                      ▼
   │                                        YOU approve + merge
   └── after 3 fails → label human-needed          (the only manual step)
```

## Files

| Path | Role |
|------|------|
| `.github/workflows/ci.yml` | The test/lint gate everything keys off. |
| `.github/workflows/claude-issue-to-pr.yml` | Labeled issue → Claude implements → **draft** PR. |
| `.github/workflows/auto-fix-ci.yml` | CI failed → Claude reads logs, pushes a fix (≤3 tries). |
| `.github/workflows/keep-prs-green.yml` | Scheduled: update stale branches, resolve conflicts. |
| `.github/workflows/pr-state-manager.yml` | Flip draft↔ready + manage labels on CI outcome. |
| `.github/labels.yml` / `scripts/setup-labels.sh` | The status-label vocabulary. |
| `.github/ISSUE_TEMPLATE/agent-task.yml` | Well-scoped issue form (auto-labels `agent`). |
| `CLAUDE.md` | Conventions + security preamble Claude loads first. |
| `docs/SETUP.md` | Step-by-step setup (App token, branch protection, etc.). |
| `orchestrator/` | Optional self-hosted alternative (`claude -p` poller for a homelab). |
| `src/`, `test/`, `package.json` | A tiny real project so CI actually runs. |

## Two design decisions that make it work

1. **Everything the bot pushes uses a dedicated GitHub App token**
   (`actions/create-github-app-token@v2`), not the default `GITHUB_TOKEN`.
   `GITHUB_TOKEN` commits don't trigger downstream workflows, so CI would never
   re-run on a fix — the loop would silently stall. See `docs/SETUP.md` §2.

2. **The human merge gate is preserved by design.** Branch protection requires
   1 approval, and a bot can't approve its own PR. So no automation can
   self-merge; your approve+merge click is structurally required. (Want fully
   hands-off? `docs/SETUP.md` §3 shows how to relax it — not recommended until
   you've watched it behave.)

## Quick start

```bash
# 1. Install the Claude GitHub App + add ANTHROPIC_API_KEY  (docs/SETUP.md §1)
# 2. Create the "Fixer" GitHub App, add FIXER_APP_ID + FIXER_APP_PRIVATE_KEY  (§2)
# 3. Turn on branch protection: require CI + 1 approval + up-to-date  (§3)
gh auth login
./scripts/setup-labels.sh                                          # (§4)
# 4. Open an issue with the "Agent task" template and watch the PR board.  (§5)
```

## Guardrails built in

- **Loop breaker**: max 3 auto-fix attempts, then `human-needed`.
- **Concurrency**: one fix/CI run per branch; supersede-and-cancel.
- **Cost caps**: `--max-turns` per run + a spend cap on your API key.
- **Prompt-injection defense**: `CLAUDE.md` treats issue/PR/CI text as data, and
  `--allowedTools` is scoped narrowly (no unrestricted shell).
- **No fork surprises**: `workflow_run` jobs guard on same-repo head, so fork PRs
  never get checked out/executed with your secrets.
- **Public-repo hardening**: outsiders can't self-trigger; an `authorize` job
  fails closed on the label-applier's permission. Full threat model in
  [`docs/SECURITY-PUBLIC-REPO.md`](docs/SECURITY-PUBLIC-REPO.md) — **read this
  before pointing it at a public repo.**

## Caveats

Claude Code and its GitHub Action move fast. Before relying on this, verify the
`anthropics/claude-code-action@v1` inputs, the current model name
(`claude-sonnet-4-6` here is a placeholder to confirm), and branch-protection
behavior against <https://docs.claude.com> and GitHub's docs. `mergeStateStatus`
is computed asynchronously and is technically undocumented — treat it as
advisory, which the scheduled sweep already does.
