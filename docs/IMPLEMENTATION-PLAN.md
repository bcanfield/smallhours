# smallhours — Implementation Plan

Build plan for the system specified in `DESIGN.md`. Read that first; this doc
assumes its vocabulary (`CONTEXT.md`) and decisions (`adr/`). Milestones are
ordered by dependency; each has acceptance criteria. Nothing here re-litigates
a decision — if a milestone can't be built as specified, that's a finding to
bring back to the maintainer, not a license to redesign.

## Prerequisites (human, one-time)

- [x] Create the public **toolkit repo** — `bcanfield/smallhours`, public.
- [x] Claude subscription token stored as repo secret
      `CLAUDE_CODE_OAUTH_TOKEN` (1-year expiry — calendar a renewal).
- [ ] Create the **Fixer GitHub App**: Repository permissions Contents R/W,
      Issues R/W, Pull requests R/W, Actions Read. Note App ID; generate
      private key. This identity signs all automation pushes (required so
      pushes re-trigger CI; `GITHUB_TOKEN` pushes don't).
- [ ] Account hardening (ADR 0002 precondition for the floating tag): 2FA/
      passkeys; toolkit repo branch protection.

## Milestone 0 — Spikes (gate *how*, not *whether*) — ✅ DONE 2026-07-17

> Both spikes passed (run `29605887740`, `ubuntu-24.04`). **0a:** egress is
> containable, but only under `claude -p --permission-mode acceptEdits` +
> managed `sandbox.enabled` + `autoAllowBashIfSandboxed`; the originally
> specified `--dangerously-skip-permissions` *disables* the sandbox. bubblewrap
> works with the required `bwrap` AppArmor profile (no iptables fallback). Full
> write-up: **ADR 0001 addendum**. **0b:** job-level `concurrency:` serializes
> from inside the called reusable workflow; stubs stay thin (ADR 0002 holds).
> Neither fallback below was needed. Experiments + outcomes live in `spikes/`.

**0a. Sandbox on a hosted runner.** In a throwaway workflow on `ubuntu-latest`
(plain VM job, NOT a container job): install pinned Claude Code, configure the
native sandbox with `sandbox.network.allowedDomains` (GitHub + Anthropic
domains only), run `claude -p` with `--dangerously-skip-permissions` on a
trivial task, then prove containment: an in-sandbox `curl https://example.com`
must fail while `gh api /user` and the Claude API succeed. Watch for the
Ubuntu 24.04 AppArmor/bubblewrap userns issue (see research doc).
*Fallback if bubblewrap fails:* the reference `init-firewall.sh` iptables
approach directly on the VM (sudo is available). Record the outcome as ADR
0001 addendum.

**0b. Concurrency inside a called reusable workflow.** Toolkit repo: a
reusable workflow whose job declares
`concurrency: { group: spike-${{ github.event.issue.number }}, cancel-in-progress: false }`;
a stub that calls it on `issues: labeled`. Apply a label twice fast; confirm
the second run queues (not parallel, not lost).
*Fallback:* concurrency declared in the stub (accepted stub-fattening, ADR 0002).

## Milestone 1 — Toolkit repo skeleton

```
smallhours/
├── README.md
├── CONTEXT.md, docs/…                  # this design corpus moves in
├── versions.env                        # CLAUDE_CODE_VERSION, GH_VERSION, … (future Dockerfile input)
├── .github/workflows/
│   ├── agent-loop.yml                  # THE reusable workflow (workflow_call)
│   └── release.yml                     # tags vX.Y.Z, moves floating v1 (only way the tag moves)
├── scripts/                            # portable brains; bash + gh only, no YAML logic
├── prompts/                            # per-stage prompt templates
├── stub/agent-loop.yml                 # the template consumers copy
└── setup/
    ├── setup-repo.sh                   # one-command consumer onboarding
    └── doctor.sh                       # drift check for an onboarded repo
```

Acceptance: `release.yml` cuts `v0.1.0` and moves `v1`; repo is marked a
template repository.

## Milestone 2 — Portable scripts (Phase 1 set)

Each script: bash, `gh` + `jq` only, repo-agnostic, config from
`.smallhours.yml` (defaults baked into `lib/config.sh`). All state mutations
go through `lib/state.sh`, which enforces the exactly-one-state-label
invariant (replace, never accumulate).

| Script | Responsibility (transitions from DESIGN.md) |
|---|---|
| `lib/config.sh` | Load consumer config + defaults; expose stage model/max-turns |
| `lib/state.sh` | Atomic issue-state transitions; PR marker labels |
| `lib/claude-run.sh` | Sandbox setup + `claude -p --permission-mode acceptEdits` (NOT `--dangerously-skip-permissions` — spike 0a / ADR 0001 addendum) + JSON result capture |
| `authorize.sh` | T1 gate: labeler has write? Fail-closed: remove label + comment on deny |
| `implement.sh` | T1: branch `agent/issue-N` (or `-rK` on retry), run implement prompt |
| `open-pr.sh` | T1 tail, deterministic: commits→draft PR (`agent` label, `Closes #N`); no commits→`ready-for-human`; branch-but-no-PR fallback |
| `state-manager.sh` | T2 (green+CLEAN→ready, issue `in-review`) / T3 (red→stay draft +`ci-failing`, issue `ready-for-human` in Phase 1) |
| `address-review.sh` | T7: only `changes_requested` from write+ users; PR→draft, issue→`agent-working`, run review prompt |
| `cancel.sh` | T9/T10/T11: close PR, comment, delete branch |
| `report-usage.sh` | Per-run PR comment: turns, duration, stage |

Acceptance: each script runnable locally against a test repo with only
`GH_TOKEN` + config env set (this is the self-hosted portability contract).

## Milestone 3 — `agent-loop.yml` reusable workflow

`on: workflow_call`. First job mints the App token
(`actions/create-github-app-token`); routing on `github.event_name` +
qualifiers (caller's event context flows through):

| Caller event | Route |
|---|---|
| `issues` labeled `ready-for-agent` | `authorize.sh` → job 2: `implement.sh` + `open-pr.sh` |
| `issues` closed / unlabeled while `agent-working` | `cancel.sh` |
| `pull_request_review` submitted, `changes_requested` | `address-review.sh` |
| `workflow_run` completed (consumer CI) | `state-manager.sh` — hard-gate: same-repo head AND PR has `agent` label |
| `schedule` | **no-op in Phase 1** (routes to sweep in Phase 2 — stubs never change) |

Job-level details per DESIGN: per-issue concurrency (spike 0b shape),
timeouts (implement 40m, others 15m), narrowest per-job permissions.

Acceptance: all Phase 1 transitions fire from a stub-equipped test repo.

## Milestone 4 — Consumer onboarding

- `stub/agent-loop.yml`: all five triggers (schedule included, no-op),
  permissions ceiling, one `uses: …/agent-loop.yml@v1`, secret wiring
  (`CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_APP_ID`, `AGENT_APP_PRIVATE_KEY`).
- `setup-repo.sh <owner/repo>`: install Fixer App on the repo; push stub +
  default `.smallhours.yml`; create the label vocabulary (both axes); branch
  protection (require PR, 1 approval, CI check, up-to-date); enable
  secret-scanning push protection; verify a CI workflow exists (warn if not —
  the loop keys off it).
- `doctor.sh <owner/repo>`: re-check all of the above + stub version drift;
  exit nonzero on drift.

Acceptance: a fresh repo onboards with one command; `doctor` is clean;
breaking any precondition makes `doctor` fail.

## Milestone 5 — Guinea-pig validation (gates Phase 2)

Onboard one real repo; run the acceptance scenarios:

1. Happy path: label → draft PR → green → `in-review` → approve+merge →
   issue closed, branch deleted.
2. Request changes → agent revises → green → `in-review` again (T7 loop).
3. Impossible task (no commits) → `ready-for-human`, no ghost PR.
4. Red CI → PR draft + `ci-failing`, issue `ready-for-human` (Phase 1 T3).
5. Human rescue commit on the agent branch → green → normal T2.
6. Cancel: close issue mid-run → PR closed, branch gone (T10); same via
   label removal (T11).
7. Double-label while working → exactly one implementation run (spike 0b).
8. PR closed unmerged → `ready-for-human` (T9).
9. Board audit after all of the above: every issue has exactly one state
   label; no PR in an ambiguous state; usage comment on every agent PR.

Run ~a dozen real issues through before opening Phase 2.

## Phase 2 milestones (after Milestone 5 sign-off)

- **M6 auto-fix:** `auto-fix.sh` on the `workflow_run` red path (replaces
  Phase 1's T3 routing): `agent`-labeled PRs only, ≤3 *consecutive* attempts
  (`autofix-attempt-*` labels stripped on any green), then T4 give-up.
- **M7 sweep:** schedule route goes live: BEHIND→`update-branch`;
  DIRTY→conflict-resolution stage (one per run); watchdog (`agent-working` +
  no open PR >1h → `ready-for-human`); label-invariant reconciliation.
  `UNKNOWN` merge state → skip.

## Future (out of scope until scheduled)

GitLab port (CI/CD component + webhook→pipeline-trigger bridge + schedules) ·
self-hosted runtime · GHCR image built from `versions.env` (ADR 0002) ·
issue-comment grilling bot · model auto-escalation.

## Consumer config schema (`.smallhours.yml`, all keys optional)

```yaml
version: 1
models:        { implement: claude-sonnet-5, address_review: claude-sonnet-5,
                 auto_fix: claude-sonnet-5, resolve_conflict: claude-sonnet-5 }
max_turns:     { implement: 50, address_review: 30, auto_fix: 25, resolve_conflict: 20 }
attempt_cap: 3
ci_workflow: ci            # name the workflow_run gate keys off
egress_extra_domains: []   # appended to the sandbox allowlist
npm_allowed: false         # when true, ignore-scripts=true is enforced
```

## Risk register

| Risk | Mitigation |
|---|---|
| Spike 0a fails both ways (no VM sandbox) | Stop; revisit ADR 0001 with maintainer — do not ship allowlist-only |
| Subscription quota exhausted mid-run | `claude-run.sh` treats CLI failure as give-up → `ready-for-human`, never retry-loops |
| Floating-tag compromise | Release-workflow-only tag moves; account hardening (ADR 0002) |
| Prompt injection via issue text | Residual by design: sandbox egress + review gate + "only label issues you understand" |
| GitHub API rate limits (App token) | All loops bounded; sweep is 1 Claude run max per cycle |
| Stub drift across consumers | `doctor.sh` in a scheduled toolkit-repo audit over all onboarded repos |
