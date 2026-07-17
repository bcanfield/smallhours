# Sandbox is the boundary, not tool allowlists; direct CLI, not the GitHub Action

The agent must run repo tests, so it executes repo code by design — tool
allowlists cannot contain a code-writing agent and pretending otherwise gives
false safety. We instead run the Claude Code CLI directly (`claude -p`) with
`--dangerously-skip-permissions`, contained by the environment: an egress
domain allowlist (native bubblewrap sandbox, or the reference devcontainer
firewall as fallback), an ephemeral runner, a repo-scoped 1-hour GitHub App
token, secret-scanning push protection, and a mandatory human review before
merge. Auth is a Claude subscription OAuth token (`claude setup-token`, passed
as `CLAUDE_CODE_OAUTH_TOKEN`), never a metered Anthropic API key.

## Considered Options

- **Tool allowlists via `--allowedTools` (the original proposal's posture)** — rejected:
  running `node --test` executes arbitrary repo code regardless, so the
  allowlist only stops casual damage while complicating every workflow.
- **`anthropics/claude-code-action`** — rejected: it does not create PRs
  deterministically, bills per-token unless given the same OAuth token, and a
  direct CLI invocation is the identical command a future self-hosted runner
  would use (portability requirement).
- **Hard containment (secretless test jobs, key proxies)** — deferred, not
  rejected; revisit if the system outgrows the current blast radius.

## Consequences

- The subscription's rate limits are the de-facto spend cap; unattended runs
  share quota with interactive use. `--max-turns` and the fix-attempt cap are
  the throttles.
- The sandbox runs directly on the runner VM, never inside a container job:
  bubblewrap is documented as failing (or requiring a weakened mode) inside
  containers, and Docker container actions cannot add NET_ADMIN for an
  iptables firewall. A one-hour spike must confirm bubblewrap's egress
  allowlist on a hosted runner; fallback is the reference `init-firewall.sh`
  iptables approach on the VM.
- Residual channel: injected code convincing the agent to commit a secret to a
  public branch — mitigated by push protection and pre-merge review, not
  eliminated.
