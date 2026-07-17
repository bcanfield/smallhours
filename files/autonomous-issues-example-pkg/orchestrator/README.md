# Homelab orchestrator (optional)

An alternative to running the auto-fix loop on GitHub Actions. This polls the
GitHub API from your own hardware and invokes Claude Code headless (`claude -p`).

**Use the GitHub Actions workflows OR this — not both on the same repo**, or
they'll fight over the same PRs.

## When to prefer this

- You have a k3s/Docker homelab and want to avoid GitHub Actions minutes.
- You want a central cost ledger (`total_cost_usd` is summed across runs).
- You want a real attempt counter / state store (swap the in-memory dict for
  SQLite or Redis).
- Data residency: only the Anthropic API call leaves your network.

## Run it

```bash
export ANTHROPIC_API_KEY=sk-ant-...
gh auth login                      # a machine account with repo access
git clone https://github.com/owner/name /srv/repo

python3 orchestrator.py --repo owner/name --repo-dir /srv/repo
# single pass for testing:
python3 orchestrator.py --repo owner/name --repo-dir /srv/repo --once
```

## As a container / k3s CronJob

Build a small image with `gh`, the `claude` CLI, `git`, and this script, then run
it either as a long-lived Deployment (the built-in poll loop) or as a CronJob
with `--once`. Mount the repo clone as a volume and the API key as a Secret.

## What it does NOT do

- It does not open the initial PR from an issue — keep
  `claude-issue-to-pr.yml` on GitHub for that, or extend this to watch issues.
- Conflict (`DIRTY`) resolution is stubbed; mirror the `keep-prs-green.yml`
  approach to finish it.
- It never merges. Human approval + merge stays manual by design.

Treat this as a starting skeleton; add locking, retries, and durable state
before trusting it unattended.
