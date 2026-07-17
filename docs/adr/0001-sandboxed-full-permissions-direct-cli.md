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

## Addendum — Spike 0a outcome (2026-07-17)

Spike 0a ran the sandbox on a GitHub-hosted `ubuntu-24.04` runner (kernel
6.17.0-1020-azure, non-root `runner` user) and overturned one load-bearing
assumption in the decision above. Evidence: workflow run `29605252082`,
two profiles (baseline = sandbox + allowlist only; hardened = + lockdown keys),
each probed under two invocations.

**Finding 1 — `--dangerously-skip-permissions` disables the Bash sandbox.**
The decision specifies `claude -p --dangerously-skip-permissions` *inside* the
sandbox. But that flag is exactly `--permission-mode bypassPermissions`, and
Claude Code's Bash sandbox is a *permission-granting* mechanism: it auto-allows
a command **because** it is sandboxed. Bypass the permission decision and the
bwrap wrapper is never invoked — commands run with the host's raw network.

Measured, identically on both profiles:

| Invocation | example.com / pypi.org | api.github.com / api.anthropic.com |
|---|---|---|
| `--dangerously-skip-permissions` (as written) | **reachable (200)** — leak | reachable |
| `--permission-mode acceptEdits` + `autoAllowBashIfSandboxed` | **blocked (curl 56)** | reachable |

The allowlist only holds under `acceptEdits`. Containment tracked the permission
mode, not the lockdown keys — baseline and hardened behaved identically.

**Decision revision.** The unattended invocation is
`claude -p --permission-mode acceptEdits` with managed `sandbox.enabled: true`
and `autoAllowBashIfSandboxed: true`, **not** `--dangerously-skip-permissions`.
This stays unattended-safe: auto-allow runs sandboxed Bash without prompting
(the probe agent completed clean — `is_error: false`, 2 turns, 5s), and a
command that cannot be sandboxed falls to the permission flow, which in headless
mode denies rather than hangs. "Denied, not hung" is the correct failure for an
autonomous run. Since the loop never runs as root, dropping the flag also
removes the root-block concern the flag was partly there to satisfy.

**Finding 2 — the sandbox covers the Bash tool only** (the original
`sandbox-boundary-scope` debt). `sandbox.network`/`sandbox.filesystem` do not
constrain `WebFetch`/`WebSearch` (separate egress) or `Write`/`Edit` (separate
filesystem). Mitigations, now part of the shipped posture: deny `WebFetch`/
`WebSearch` via `permissions.deny` + `allowManagedPermissionRulesOnly` (so a
consumer repo's own settings cannot re-allow them); accept the `Write`/`Edit`
blast radius as bounded to the ephemeral runner. `@anthropic-ai/sandbox-runtime`
(wraps the whole Claude Code process, not just Bash) remains the escalation if
one boundary over every tool is later required.

**Finding 3 — bubblewrap works on the hosted runner, with the documented
caveat.** `ubuntu-24.04` enforces `kernel.apparmor_restrict_unprivileged_userns
= 1`, so the `bwrap` AppArmor profile from the Claude Code docs is **required**;
with it installed, bwrap creates user namespaces and isolates normally. The
`init-firewall.sh` iptables fallback was **not** needed and is not adopted.

Two lockdown keys are mandatory even though they didn't change the egress result
here, because they close silent-failure modes: `failIfUnavailable` (without it a
missing bubblewrap downgrades to a warning and Claude runs **unsandboxed**) and
`allowManagedDomainsOnly` (without it a new domain prompts, and an unattended
`-p` run has nobody to prompt).
