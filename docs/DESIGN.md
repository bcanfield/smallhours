# smallhours — Design (grilled and agreed 2026-07-17)

Autonomous issue → PR system: the maintainer grills issues externally and
reviews PRs; everything between is automated. This document records the
decisions from the grilling session. Vocabulary: see `CONTEXT.md`. Rationale
for the security posture: see `docs/adr/0001`.

## Scope decisions

| Decision | Choice |
|---|---|
| Repo visibility | Public assumed (must not break on private) |
| Repo count | Multi-repo from the start; stampable per-repo setup |
| Runtime v1 | GitHub Actions; logic in portable scripts so GitLab CI / self-hosted can reuse them later |
| Grilling | External. Input contract = fully described issue + `ready-for-agent` label |
| Agent runtime | Claude Code CLI directly (`claude -p`), NOT claude-code-action |
| Auth/billing | Claude subscription OAuth token (`claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` secret). Never a metered API key |
| Containment | Full permissions inside egress-allowlisted sandbox (ADR 0001) |
| Build order | Phase 1 = human-triggered loop; Phase 2 = self-healing |

## Issue state machine

Exactly one state label per issue at all times; transitions replace labels.

```
needs-triage ─→ needs-info ─→ ready-for-agent ──→ agent-working ──→ in-review ──→ CLOSED (merged)
     │              │                                  │   ▲              │
     ├─→ wontfix ───┴─→ CLOSED (not planned)           │   └──────────────┘ "request changes" review
     └─→ ready-for-human                               └──→ ready-for-human (any give-up exit)
```

- `ready-for-agent` — a validated **queue**, unbounded. Applying it authorizes
  work but does not start it; the dispatcher (ADR 0005) promotes queued issues
  into free slots, at most `max_concurrent` (default 3) worked at once.
- `agent-working` — deliberately coarse (implementing, CI-fixing, conflict-resolving);
  also the WIP-slot marker the dispatcher counts. Fine-grained progress lives on the PR.
- `in-review` — the maintainer's queue: PR is ready, review is the only pending act.
- `ready-for-human` — single failure exit; the reason goes in a comment, never a label.
- Merge closes the issue via `Closes #N`.

## PR state model

No second label taxonomy: draft/ready + marker labels.

| Situation | Draft? | Labels |
|---|---|---|
| Implementing / fixing / resolving | draft | `agent` |
| CI red, attempt N≤3 (Phase 2) | draft | `agent`, `ci-failing` |
| Green + `mergeStateStatus == CLEAN` | ready | `agent`, `ready-to-merge` |
| Automation gave up | draft | `agent`, `human-needed` |

`agent` on a PR is an ownership marker (automation may touch), never a state.
`UNSTABLE` (non-required check failing) is NOT treated as ready: "ready" must
mean nothing is red when the maintainer opens the PR.

## Transitions (owner → effect)

| # | Event | Effect |
|---|---|---|
| T1 | Maintainer applies `ready-for-agent` | Authorize (labeler has write; fail-closed, remove label + comment on deny) → issue stays `ready-for-agent` (validated + **queued**). A WIP-limited **dispatcher** (ADR 0005) promotes it to `agent-working` when a slot is free → agent implements on `agent/issue-N` → deterministic step opens draft PR (never model-dependent) |
| T2 | CI green + CLEAN | PR ready + `ready-to-merge`; issue `in-review` |
| T3 | CI red (Phase 1) | PR stays draft + `ci-failing`; issue `ready-for-human` |
| T3' | CI red (Phase 2) | Auto-fix attempt N+1 of 3 (consecutive; reset on green) |
| T4 | 3rd consecutive fix fails | PR `human-needed`; issue `ready-for-human` + reason comment |
| T5 | Branch BEHIND | Sweep runs `gh pr update-branch` (no tokens) |
| T6 | Branch DIRTY | Sweep: PR to draft, agent resolves conflict, push re-runs CI |
| T7 | "Request changes" review by write+ user | PR to draft; issue `agent-working`; agent addresses review. Plain comments never trigger |
| T8 | Approve + merge | Issue auto-closed; branch deleted |
| T9 | PR closed unmerged | Issue `ready-for-human` + comment |
| T10/T11 | Issue closed, or state label removed mid-run | Cancellation: close draft PR, comment, delete branch |

## Edge-case rulings

- Re-label while `agent-working` → per-issue concurrency + resume-not-restart guard.
- Retry after failure → fresh branch `agent/issue-N-r2`; never force-push seen history.
- Issue edited after labeling → agent works from trigger-time snapshot; re-label to restart.
- No commits produced → `ready-for-human`, no ghost PR.
- Branch exists but no PR → deterministic fallback step opens it (also T1).
- Runner death → sweep watchdog: `agent-working` + no open PR after ~1h → `ready-for-human`.
- Auto-fix must gate on the PR carrying `agent` — a red CI run on a
  human-authored PR must never summon the agent.
- Attempt counter = *consecutive* failures: any green CI strips the
  `autofix-attempt-*` labels, so the cap can never fire from failures separated
  by a success.
- `mergeStateStatus UNKNOWN` → do nothing; next sweep retries.
- Sweep hard-checks same-repo head before checkout, even though `agent` label
  should already imply it.
- Label drift (two states, state contradicts PR reality) → sweep reconciles + comments.
- Human rescue commit on agent branch → welcomed; green CI resumes normal flow.

## Security posture (ADR 0001)

Sandbox is the boundary: `claude -p --permission-mode acceptEdits` (with managed
`sandbox.enabled` + `autoAllowBashIfSandboxed`) inside an egress domain
allowlist — **not** `--dangerously-skip-permissions`, which spike 0a proved
disables the sandbox (see ADR 0001 addendum). Native bubblewrap on the hosted
runner VM, confirmed working on `ubuntu-24.04` with the required `bwrap`
AppArmor profile; the iptables firewall fallback was not needed. Ephemeral
runner, repo-scoped 1-hour App token, secret-scanning push protection enabled,
human review before merge. Operational rule: only label issues you wrote or
fully understand. Residual risks accepted: injected code can read the runner
env (bounded: subscription token + repo-scoped App token); agent could commit a
secret to a public branch (push protection + review mitigate).

A dedicated GitHub App ("Fixer") signs all automation pushes — required so
pushes re-trigger CI (GITHUB_TOKEN pushes don't) and so automation identity is
distinct from the maintainer.

## Stage configuration (per-repo `.smallhours.yml`, defaults in central repo)

| Stage | Model default | max-turns default |
|---|---|---|
| implement | claude-sonnet-5 | 50 |
| address-review | claude-sonnet-5 | 30 |
| auto-fix (P2) | claude-sonnet-5 | 25 |
| resolve-conflict (P2) | claude-sonnet-5 | 20 |

Also configurable: max concurrent worked issues (`max_concurrent`, default 3 —
the dispatcher's WIP cap, ADR 0005), attempt cap (3), sweep cadence (15m), extra egress domains,
npm allowed (default false; when true, `ignore-scripts=true` enforced).
No auto-escalation to bigger models in v1; `ready-for-human` is the escape
hatch. Every agent run posts a usage comment (turns/duration) on the PR.

## Pocock protocol integration (M5.5, grilled 2026-07-17; ADR 0006)

smallhours is the **AFK implementer** for repos following the Matt Pocock flow
(grill → to-spec → to-tickets → `ready-for-agent`). Posture: **Pocock-aware,
gracefully degrading** — the "fully described issue" contract is unchanged;
Pocock artifacts are enrichment, and a repo without them behaves exactly as
before. Grilling, specs, ticket breakdown, and triage stay human-gated outside
the system.

| Concern | Decision |
|---|---|
| Ticket ordering | Edge-aware dispatcher; promotable = all blocking edges cleared (ADR 0006) |
| Edge store | Native issue dependencies; `## Blocked by` text upserted into them each tick |
| Unblock | Blocker closed `COMPLETED`; `NOT_PLANNED` ejects dependents to `ready-for-human` |
| Chains | Serialize on merge; stacked PRs out of scope (debt `chain-serialize-no-stacked-prs`) |
| Tracker context | Deterministic pre-step inlines parent spec verbatim + one-line pointer per cleared blocker |
| Checkout knowledge | Prompt directs agent to `CONTEXT.md` vocabulary, ADR guardrail (stop rather than contradict), `docs/agents/domain.md` |
| Discipline | Condensed in prompt: TDD at spec-named seams; closing self-review vs acceptance criteria + spec |
| Labels | `.smallhours.yml` `labels:` mapping (canonical → repo string); setup imports `triage-labels.md`; doctor warns on drift |
| Write boundary | Knowledge layer read-only for agents; discoveries go in a "Decisions surfaced" PR section |

## Phases

**Phase 1 — human-triggered loop:** authorize → **queue → WIP-limited dispatcher**
(ADR 0005) → implement → deterministic draft PR → CI → state-manager (T2/T3) →
request-changes re-summon (T7) → cancellation (T9–T11). Every Claude invocation
traces to an explicit maintainer act. (The dispatcher is a minimal slice of the
Phase 2 sweep, pulled forward after the M5 bulk-trigger incident to bound the
blast radius; the full sweep in Phase 2 subsumes it.)

**Phase 2 — self-healing:** auto-fix loop (T3'/T4), sweep (T5/T6, watchdog,
label reconciliation). Adopt only after Phase 1 has handled ~a dozen real
issues.

## Packaging (ADR 0002; facts in docs/research/packaging-distribution.md)

- **Toolkit repo (public):** reusable workflows carry all logic (jobs,
  concurrency groups, authorize→implement split, timeouts — all behind the
  tag), plus portable `scripts/`, a single tool-versions file, stub templates,
  and `setup-repo.sh` / `doctor` onboarding scripts. Template repository for
  seeding new consumers.
- **Consumer repos:** one thin stub — `on:` triggers + permissions ceiling +
  `jobs.loop.uses: <toolkit>/.github/workflows/agent-loop.yml@v1` + secret
  wiring — plus `.smallhours.yml` config. Nothing else.
- **Versioning:** floating `v1` tag moved only by a release workflow; breaking
  changes cut `v2`. SHA-pinning revisited only if third-party consumers appear.
- **GHCR image:** deferred until the GitLab/self-hosted milestone; the
  versions file is its future Dockerfile input. GitLab port = CI/CD component
  + webhook→pipeline-trigger bridge + pipeline schedules, reusing the same
  scripts.

## Open items

- ~~Phase 1 spike: bubblewrap egress allowlist on a hosted runner.~~ **Resolved
  2026-07-17** (run `29605252082`): bubblewrap contains egress on `ubuntu-24.04`
  with the `bwrap` AppArmor profile; the decisive change is `--permission-mode
  acceptEdits` over `--dangerously-skip-permissions`. See ADR 0001 addendum.
- ~~Phase 1 spike: job-level `concurrency:` inside called reusable workflows.~~
  **Resolved 2026-07-17**: runs serialize when the group is declared in the
  called workflow; stubs stay thin (ADR 0002 holds).
