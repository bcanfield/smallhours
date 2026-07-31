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

## Milestone 1 — Toolkit repo skeleton — ✅ DONE 2026-07-17

> Skeleton laid down; `release.yml` implemented fully (the one M1 acceptance
> criterion) and `bcanfield/smallhours` marked a template repository.
> `agent-loop.yml`, `scripts/`, `prompts/`, `stub/`, and `setup/` exist as
> honest skeletons/placeholders that name the milestone that fills them (M2–M4).
> Release semver-channel policy recorded as **ADR 0003** (0.x floats under the
> `v1` channel; `>=1.0.0` must float its own major).

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

## Milestone 2 — Portable scripts (Phase 1 set) — ✅ DONE 2026-07-17

> All Phase-1 scripts built under `scripts/` (libs in `scripts/lib/`), plus
> `prompts/implement.md` + `prompts/address-review.md` and the default
> `stub/.smallhours.yml`. Config/label/settings/helper logic tested locally
> (yq→jq path, defaults fallthrough, managed-settings render, verbatim prompt
> render, live read-only `gh`). Toolchain gained pinned **`yq`** to read YAML
> config (**ADR 0004** — jq can't parse YAML). Open findings surfaced to the
> maintainer: T9 needs a `pull_request:[closed]` trigger (M3/M4 wiring); a
> green-but-not-CLEAN PR stays draft with no Phase-1 rescue (Phase-2 sweep);
> both in `docs/debt/`. Full end-to-end (mutating) exercise is Milestone 5.

Each script: bash, `gh` + `jq` (+ `yq` for config, ADR 0004) only, repo-agnostic, config from
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

## Milestone 3 — `agent-loop.yml` reusable workflow — ✅ DONE 2026-07-17

> Full routing workflow built (replaces the M1 skeleton): per-route jobs mint
> the Fixer App token, self-check-out the toolkit at the exact invoked version
> via `job.workflow_repository`@`job.workflow_sha` (verified against GitHub's
> contexts reference — actionlint ≤1.7.x flags these on a stale schema; false
> positive), and call the M2 scripts. authorize→implement `needs:` split;
> per-issue/-PR/-branch `concurrency` (spike 0b); timeouts 40m implement /
> address-review, 15m others; schedule no-op. Stub secret-wiring uncommented so
> the call validates. Statically validated (ruby YAML + actionlint clean bar the
> false positives). **End-to-end firing is gated on the Fixer App prerequisite
> (still unchecked) + secrets + a test repo — that is Milestone 5's acceptance.**

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

## Milestone 4 — Consumer onboarding — ✅ DONE 2026-07-17

> `setup-repo.sh` + `doctor.sh` built and run live against the guinea-pig
> `bcanfield/mediamtx-connect`: 13-label vocabulary created, secret-scanning
> enabled, the CI workflow name auto-detected (`CI`) and substituted into the
> stub/config. Both scripts are **ruleset-aware** (the real-world case the plan
> didn't anticipate): mediamtx-connect protects `main` with a *ruleset* not
> legacy protection, so setup lands the stub + config via an **onboarding PR**
> (PR #194) instead of a rejected direct push and leaves the existing ruleset
> untouched; `doctor` reads effective rules (not just legacy). `doctor` is clean
> except the stub/config, which read MISSING until PR #194 is merged (correct —
> that IS the "breaking a precondition fails doctor" behaviour). Deferrals in
> `docs/debt/`: Fixer-App install is a manual UI step (not automatable with a
> user token), and required-check auto-detection is weak for rulesetless repos.
> **The App-install + `ready-for-agent` trigger is Milestone 5.**

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

## Milestone 5.5 — Pocock protocol integration (after M5 sign-off; ADR 0006)

> **VALIDATED 2026-07-25** on mediamtx-connect (shipped v0.4.0–v0.4.2): all
> three acceptance scenarios passed — chain A←B dispatched serially on merge,
> NOT_PLANNED blocker ejected its dependent (once, with marker comment),
> unresolvable ref stayed queued fail-closed with exactly one comment. First
> full T7 loop also ran and exposed a structural stranding (green revision
> can't reach in-review while the changes-requested review blocks; approval
> fires no re-check) — recorded in debt `phase1-green-not-clean-stranding`
> with the sweep-fix sketch. Tickets smallhours#7–#12 closed.

Make smallhours the AFK implementer for repos using the Pocock flow
(grill → to-spec → to-tickets → `ready-for-agent`). Design: DESIGN.md
§ Pocock protocol integration; decisions + full spec and six-ticket DAG:
**ADR 0006 appendix** (publish the tickets as real issues, blockers first with
native dependency edges, when this milestone starts — debt
`m6-tickets-in-adr-appendix`). ~~Operational prerequisite: grant the Fixer App
issue-dependencies write permission.~~ (Moot — dependencies endpoints ride
under the App's existing issues:write; ADR 0006 appendix correction.)
Frontier at start: 06-1 (label mapping),
06-4 (context assembly), 06-5 (prompt discipline); then 06-2 → 06-3
(edge-aware dispatch, plan-change ejection) and 06-6 (setup & doctor).

## Phase 2 milestones (after Milestone 5.5)

- **M6 auto-fix:** `auto-fix.sh` on the `workflow_run` red path (replaces
  Phase 1's T3 routing): `agent`-labeled PRs only, ≤3 *consecutive* attempts
  (`autofix-attempt-*` labels stripped on any green), then T4 give-up.

  > **VALIDATED 2026-07-25** live on mediamtx-connect (v0.4.3, issue #248 /
  > PR #249): deliberate typecheck break → T3' minted `autofix-attempt-1` and
  > summoned auto-fix, which removed the broken file (15 turns · 56s) → green
  > stripped the attempt label and re-fired T2. With `autofix-attempt-3`
  > pre-set, the next red hit T4 exactly once (`human-needed`, issue
  > `ready-for-human`, one comment, `auto_fix` job **skipped** — no Claude
  > spend at cap); a further red logged the idempotent no-op. Human rescue
  > after T4 → green stripped all three markers and re-fired T2 (via a
  > `gh run rerun` after an unrelated E2E flake — live proof of debt
  > `autofix-burns-attempt-on-flaky-ci`).
  >
  > Implementation (2026-07-24): state-manager.sh now
  > owns the red-path decision (T3' grant printed as `autofix=<n>` on stdout,
  > T4 at `attempt_cap` with idempotent re-red no-op); attempt counting lives
  > in `lib/state.sh` as one `autofix-attempt-N` PR label at a time (system
  > literal, not in the `labels:` mapping — created on demand, pre-created
  > with colors by setup). New `auto_fix` workflow job (sandbox, PR-head
  > checkout, failing-check names + failed-job log tail as context); a no-diff
  > agent run is a give-up, not a silent strand. `attempt_cap: 0` disables
  > auto-fix. Offline tests in `tests/test-autofix.sh`. Validate on
  > mediamtx-connect: red CI → attempt labels advance → green strips them, and
  > a forced triple-red reaches T4 exactly once.
- **M7 sweep:** schedule route goes live: BEHIND→`update-branch`;
  DIRTY→conflict-resolution stage (one per run); watchdog (`agent-working` +
  no open PR >1h → `ready-for-human`); label-invariant reconciliation.
  `UNKNOWN` merge state → skip.

  > **VALIDATED 2026-07-25** live on mediamtx-connect (v0.5.0–v0.5.2): T5
  > twice (BEHIND → App-authored update merge → green → T2 re-fired); T6 end
  > to end (DIRTY → draft → agent resolved an add/add conflict preserving both
  > sides, 7 turns · 33s → push → green → T2; give-up path also exercised —
  > human-needed + ready-for-human + reason, and the sweep skips human-needed
  > DIRTY PRs instead of retrying every tick, found+fixed in v0.5.1); watchdog
  > both via env override and at the real 60m threshold in-workflow (⏰
  > reclaim to ready-for-human); label reconciliation (double state label →
  > exactly one + 🧹 comment); T9 twice (human-closed agent PR → 🚪 hand-back;
  > Bot-closed PRs correctly ignored); and the full stranding replay on a real
  > loop PR — changes-requested → green revision → BLOCKED (stranded exactly
  > as the old debt described) → approval fired review_reeval (transient
  > UNSTABLE correctly held) → the sweep's green-reeval backstop promoted →
  > merge → T8. Two live root-causes fixed en route: hosted runners have no
  > git ident so `git merge` dies with "empty ident name" (v0.5.2 passes
  > identity on the merge; v0.5.1's never-swallow-merge-output diagnostics
  > found it), and the T6 retry-forever gap above. Doctor clean; board audit
  > clean.
  >
  > **IMPLEMENTED 2026-07-25.** `sweep.sh` (decider,
  > no sandbox) runs on schedule *and* a new stub `workflow_dispatch` (manual
  > tick — the repo's cron is chronically laggy); it emits at most one
  > `conflict=<pr>` per tick for the new `resolve_conflict` job
  > (`resolve-conflict.sh` + prompt: merge base in-progress, agent resolves,
  > system commits the merge; unresolved conflicts = give-up). Decisions live
  > as pure helpers in `lib/sweep.sh` (tests/test-sweep.sh). Also folded in:
  > T9 wiring (`pull_request: [closed]` in the stub; human-sender + unmerged +
  > `agent`-label gated), the approved/dismissed-review → green-gated T2
  > re-eval (`reeval.sh`, closes debt `phase1-green-not-clean-stranding` —
  > sweep re-evals green PRs as backstop), retry-attempt derivation from
  > surviving `agent/issue-N[-rK]` branches (closes `rerun-reuses-agent-branch`),
  > and the copy-pasted yq/config step became the `consumer-config` composite
  > action riding the toolkit self-checkout (closes
  > `config-fetch-step-duplicated`). Watchdog threshold 60m
  > (`SMALLHOURS_WATCHDOG_MINUTES` override for testing); implement's 40m
  > timeout can't trip it. Stub gained triggers → consumers re-sync via setup.

## Milestone 8 — Onboarding UX

Target user: an external developer with a Claude subscription and ~15
minutes who will not read DESIGN.md. Decisions grilled 2026-07-25. In build
order:

1. **Docs: prerequisites walkthrough.** GETTING-STARTED becomes a numbered
   path: clone the toolkit; create the Fixer App (manual UI steps incl. the
   webhook-must-be-unchecked tripwire — kept as fallback text once
   `create-app.sh` exists); provenance + exact `gh secret set` command for
   each of the three secrets (incl. `claude setup-token`); the install click
   with its deep link. README "Start" updated to match.
2. **Docs: "First run" canary section.** A deliberately trivial issue
   template plus the transition-by-transition "what you should see" list
   (stub fires → `agent-working` → draft PR → green → ready + `in-review` →
   merge → branch gone, issue closed); each step doubles as a diagnostic for
   where the wiring is broken.
3. **`setup/create-app.sh`.** GitHub App **manifest flow** (localhost
   listener, browser pre-filled with name/permissions/webhook-off, `--org`
   supported); exchanges the callback code for App ID + PEM, sets both
   secrets via `gh secret set`, then verifies installation and prints the
   `github.com/apps/<slug>/installations/new` deep link when missing.
4. **Actionable failures.** Every ✗/⚠ in `setup-repo.sh` and `doctor.sh`
   carries its one-line remedy (exact command or a GETTING-STARTED anchor —
   never an inlined paragraph). `doctor.sh` gains a secret-free best-effort
   App-install check (a past successful `agent-loop` run proves token
   minting; none + zero runs = "likely not installed" warning). Retires debt
   `fixer-app-install-manual`.
5. **Ending checklist.** Setup always ends with a met/unmet checklist
   (✓/✗ + Q-item remedies); the protected-branch onboarding PR body mirrors
   it. Landing semantics unchanged (direct push when unprotected, PR when
   protected).

Out of scope (decided): hosted/one-click App (contradicts the
maintainer-owned-Fixer posture) · `curl | bash` installer (off-brand for the
security posture) · zero-spend `--smoke` mode (test mode inside the
production loop, disproportionate for v1).

Acceptance: a fresh external developer goes clone → App → secrets → setup →
canary-merged using only GETTING-STARTED; every failure they can hit on the
way prints its own remedy; `doctor` flags a missing App install.

> **IMPLEMENTED 2026-07-25.** `setup/create-app.sh` registers the Fixer via
> the App manifest flow (auto-submitting local form → GitHub confirm page →
> localhost `nc` listener catches the redirect → one-time code exchanged for
> App ID + PEM), sets both App secrets, keeps the key under `~/.smallhours/`
> (doctor's authoritative check reads it), and deep-links the one remaining
> human click (`…/installations/new`), verifying as the App afterwards.
> Webhook-off is structural — the manifest carries no `hook_attributes`
> (pinned by tests). GETTING-STARTED became the numbered six-step walkthrough
> (manual App registration kept as fallback with the webhook tripwire called
> out; secrets provenance table; canary section with per-transition
> diagnostics); README Start matches. Every ✗/⚠ in setup-repo/doctor carries
> its one-line remedy; doctor's App check falls back secret-free to run
> evidence (a past successful `agent-loop` run proves token minting) —
> retires debt `fixer-app-install-manual`. Setup ends with the met/unmet
> checklist (`lib/onboarding.sh`, `tests/test-onboarding.sh`) and mirrors it
> into the onboarding PR body. Not yet validated on a fresh consumer.

> **2026-07-26.** GETTING-STARTED gained the delegate-to-agent path: one
> paste-prompt plus an agent contract (scriptable steps vs the four
> human-reserved moments, sequencing rules, doctor-as-verifier, secret
> hygiene, headless fallback); README Start is the paste-prompt alone.
> Prompt over packaged skill: debt `agent-setup-prompt-not-skill`.
> Tabletop-validated the same day by a fresh agent walking the doc
> against a fictional consumer; fixes it forced: `create-app.sh` no
> longer dies without a TTY, doctor's CI check gates on the configured
> `ci_workflow` (exact-case, case-mismatch gets its own remedy), and the
> secrets check notes it proves presence only.

## Production rollout — mediamtx-connect (2026-07-26 → 07-29)

Trickle rollout under a 3-hourly babysitter routine, logged in smallhours#20.
Twelve queued issues fed one at a time; **nine merged**, two needed a manual
retry after an unrelated consumer CI fix, one (#209) gave up twice on scope.
No state-machine defect appeared: every transition the log records — give-up,
handback, T9, watchdog reclaim, double-label reconciliation — behaved as
DESIGN specifies. What the rollout found instead was in the seams.

> **FIXED 2026-07-29.** (1) A rejected `git push` fell off `set -e` in all four
> pushing stages with no comment and no state change, stranding
> mediamtx-connect#214 in `agent-working` on a dead branch until the watchdog
> reclaimed it ~70m later (smallhours#24) — the one observed failure that
> skipped the `ready-for-human` contract entirely. `sh_push` now hands the
> caller git's rejection text and every stage routes it into its own give-up
> path (`tests/test-push.sh`). (2) Give-up comments could not name a cause the
> machine already knew: `.result` is empty on `error_max_turns`, so all six
> turn-cap exhaustions posted the same "failed before producing a result" and
> reading a handback meant opening the Actions tab. `claude_give_up_reason`
> synthesizes from `subtype`/`num_turns` and names the stage's own config knob.
> (3) Default `max_turns.implement` 50 → 100 and `auto_fix` 25 → 40: the
> maintainer ratcheted these live through six give-ups, and implement runs that
> *succeeded* took 52/73/76 turns — the defaults ran through the middle of real
> work rather than above it. `address_review`/`resolve_conflict` unchanged
> (never observed near their caps).
>
> **Retires debt `give-up-shows-as-red-run`.** Its criterion was "close it if
> M6 passes without the reds misleading anyone." Six give-up runs painted the
> loop red across the rollout and the operator classified every one correctly,
> never as machinery failure. Its second limb — no record survives a give-up —
> closed separately: the `Upload give-up diagnostics` artifacts keep the result
> JSON for a week, and the reason and work summary now reach the comment.
>
> **Left for the maintainer, registered as debt.** The Fixer App cannot push
> `.github/workflows/*` (`fixer-app-cannot-push-workflows`) — a grant-vs-declare
> -unsupported fork that touches ADR 0001, and the reason #214 is still open.
> The babysitter's own two blind spots are in `babysitter-prompt-not-in-repo`.
> `sweep-reeval-trusts-workflow-name` had its payoff trigger fire for real and
> was dodged consumer-side; it stays open. Undecided and not registered: `v1`
> moves only by hand, and the ~18h between merging the T2 stranding fix and
> tagging it held a green PR blocked and paused the feed for five straight
> babysitter runs — a scheduled release-on-green would close that gap without
> disturbing ADR 0003's "release.yml is the sole mover".

> **FIXED 2026-07-29 (wall-clock).** Two implement runs (mediamtx-connect
> #175, #177) were *cancelled* at the 40m job cap, and cancellation is the one
> exit that runs neither the give-up path nor `if: failure()`: no comment, no
> state change, no diagnostics, no branch — ~80m of Opus for nothing, with two
> `max_concurrent` slots held past the sweep's next tick. **ADR 0007** makes
> wall-clock exhaustion a give-up cause instead: the stage runs under `timeout`
> with a budget derived as `cap − elapsed − tail` (so provisioning overrun eats
> the agent's time, not the tail), `claude_run` synthesizes the
> `error_timeout` terminal event the CLI never emits, the handback names the
> cause and prescribes a smaller ticket (there is no consumer knob, by
> decision), and the partial work is pushed as a **branch with no PR** — a PR
> would feed auto-fix a half-implemented change. Implement's cap rises 40 → 60
> **alone**; watchdog 60 → 80 to stay above it; an `if: cancelled()` step
> reclaims the slot for the residual window. New debt:
> `orphaned-agent-branches`, `human-cancel-hands-issue-back`;
> `watchdog-threshold-not-in-config` amended, not closed — its trigger fired in
> condition but not rationale, and the ordering invariant it now carries is
> unenforced by design.
>
> **Diagnosis, not just repair.** The runs were *not* turn-capped — `max_turns`
> was never the binding constraint here. Two independent causes: (1) **sizing** —
> issue bodies split cleanly at 672 → 1315 chars between everything that has
> shipped on that repo and everything that stalled, and every stalled *title*
> enumerates multiple deliverables while every shipped one names a single one;
> (2) **undeclared dependencies** — #177 names its prerequisites under
> `## Dependencies` in prose with no issue numbers, so `edges_blocked_by_refs`
> (which reads `## Blocked by`) saw nothing, `edges_promotable` called it
> trivially promotable, and it was dispatched with its entire substrate
> missing. It is *smaller* than #178, which was parked as too big. Fix is
> upstream in `/to-tickets`, not in `edges.sh` — a parser pointed at those
> sections would find no refs to normalize. Consumer-side follow-up (re-cut
> #175, edge #177, convert the other five tickets) is tracked on that repo.

> **FIXED 2026-07-30 (out-of-tree repairs, smallhours#30).** mediamtx-connect
> #307 had green code checks and one red one — the PR title, which `open-pr.sh`
> takes from the issue title verbatim and which semantic-release parses on a
> squash-merging repo. `auto_fix` retitled the PR, the check went green, and the
> toolkit handed the PR to a human as a failure anyway: `auto-fix.sh` read an
> empty `git diff --cached` as "the agent could not fix it", which is right for
> a code failure and wrong for every repair that lives outside the tree.
> **ADR 0009**: the agent may retitle a PR — and nothing else; the body carries
> `Closes #N` and is restored if touched — and the toolkit decides by
> **observing** the pull request (a pre-run snapshot of title/body/check-rollup,
> diffed after) rather than by trusting a claim it cannot check. CI moving is a
> repair; a retitle with no CI behind it within 120s is a hand-off that names
> its own cause (the consumer's CI does not run on `pull_request: edited`); only
> a PR that did not move at all is still "made no changes". Prevention alongside
> it: `conventional_title_types` maps an issue label to a commit type at
> PR-open time, opt-in by presence, verbatim when nothing maps — a guessed
> `chore:` would drop a feature out of the release. New pure lib
> `lib/autofix.sh` fixture-tested in `tests/test-autofix.sh`, plus
> `tests/test-autofix-cleantree.sh` driving the seam end to end against stubbed
> `gh`/`claude` — the ADR 0007 lesson applied before it could bite. New debt:
> `unattributed-ci-movement-strands-pr`, `conventional-title-map-is-opt-in`.

## Future (out of scope until scheduled)

GitLab port (CI/CD component + webhook→pipeline-trigger bridge + schedules) ·
self-hosted runtime · GHCR image built from `versions.env` (ADR 0002) ·
issue-comment grilling bot · model auto-escalation · gh-extension packaging
(needs a `gh-smallhours` wrapper repo; only if adoption warrants).

## Consumer config schema (`.smallhours.yml`, all keys optional)

```yaml
version: 1
models:        { implement: claude-sonnet-5, address_review: claude-sonnet-5,
                 auto_fix: claude-sonnet-5, resolve_conflict: claude-sonnet-5 }
max_turns:     { implement: 100, address_review: 30, auto_fix: 40, resolve_conflict: 20 }
attempt_cap: 3
max_concurrent: 3          # WIP cap: max issues in agent-working at once (ADR 0005)
ci_workflow: ci            # name the workflow_run gate keys off
egress_extra_domains: []   # appended to the sandbox allowlist
npm_allowed: false         # when true, ignore-scripts=true is enforced
labels: {}                 # canonical → repo label string (06-1); ready-for-agent,
                           # agent-working, agent are fixed in v1 (workflow-gated)
conventional_title_types: {}   # issue label → commit type, e.g. {bug: fix,
                           # enhancement: feat}. Presence is the opt-in; absent
                           # means PR titles stay the issue title verbatim
                           # (ADR 0009)
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
