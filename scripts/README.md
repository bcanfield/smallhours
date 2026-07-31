# scripts/ — the portable brains

Every stage transition from `docs/DESIGN.md` as a bash script using only `gh`,
`jq`, and `yq` (ADR 0004) — no YAML control flow, no Actions-specific state.
This is the self-hosted portability contract (ADR 0001/0002): the runtime
adapter (the reusable workflow in Milestone 3, a future GitLab bridge, a
self-hosted runner) parses its native event and calls these scripts with
explicit arguments; the scripts themselves never read an event payload and never
hard-code a repo.

## Runtime contract

Every script expects:

- **`GH_TOKEN`** (or `GITHUB_TOKEN`) — authenticates `gh`.
- **`GITHUB_REPOSITORY`** = `owner/repo` — the target repo. Falls back to
  `gh repo view` when unset.
- Config is read from `.smallhours.yml` (via `SMALLHOURS_CONFIG`, else
  `$GITHUB_WORKSPACE/.smallhours.yml`, else `./.smallhours.yml`). All keys
  optional; defaults in `lib/config.sh`.

Scripts that run Claude additionally need **`CLAUDE_CODE_OAUTH_TOKEN`** and a
checked-out clone of the consumer repo, with push credentials belonging to the
Fixer App (so pushes re-trigger CI). All issue-state and PR-marker label writes
go through `lib/state.sh`, which is the sole enforcer of the exactly-one-state-
label invariant.

## Libraries (`lib/`)

| File | Role |
|---|---|
| `config.sh` | Load `.smallhours.yml` over defaults; label vocabulary + `label_for` resolver (canonical → repo string, ADR 0006/06-1); per-stage model / max-turns getters |
| `common.sh` | Repo resolution, logging, comments, prompt rendering, linked-issue + branch helpers |
| `state.sh`  | Atomic issue-state transitions (replace, never accumulate) + PR marker labels; resolves canonical → repo labels at the choke point |
| `edges.sh`  | Blocking-edge logic (ADR 0006): `## Blocked by` parsing, native-relation upserts, promotable/plan-change/cycle computation (pure functions, tested in `tests/`) |
| `tracker-context.sh` | Deterministic implement enrichment: parent spec inlined verbatim + cleared-blocker pointers |
| `claude-run.sh` | Render managed settings from config, provision the sandbox, run a stage under `--permission-mode acceptEdits`, capture JSON. CLI failure = give-up (no retry) |
| `autofix.sh` | What a clean working tree means (ADR 0009): check-rollup digest, in-flight count, and the out-of-tree / stranded / no-changes verdict. Pure — `auto-fix.sh` keeps the API calls |
| `onboarding.sh` | Setup-tools helpers (M8): App-manifest payload + callback parsing, App JWT/installation lookup, install run-evidence, ending checklist. Sourced only by `setup/*`, which run on the maintainer's machine and may additionally use `curl`/`openssl`/`nc` — the gh+jq+yq contract above binds the stage scripts, not the setup tools |

## Stage scripts

| Script | Transition | Entry point |
|---|---|---|
| `authorize.sh`      | T1 gate (fail-closed on non-write labeller) | `authorize.sh <issue> <actor>` |
| `implement.sh`      | T1 body: branch + implement prompt          | `implement.sh <issue> [attempt]` |
| `open-pr.sh`        | T1 tail: deterministic draft PR / no-commits→human | `open-pr.sh <issue> [branch] [attempt]` |
| `state-manager.sh`  | T2 / T3' / T4 from CI outcome (prints `autofix=<n>` on stdout when the caller should run auto-fix) | `state-manager.sh <pr> <success\|failure>` |
| `auto-fix.sh`       | T3' body: fix red CI on the agent PR (attempt n of `attempt_cap`) | `auto-fix.sh <pr> <attempt> [ci-run-id]` |
| `address-review.sh` | T7: changes-requested re-summon             | `address-review.sh <pr> <review-state> <reviewer>` |
| `cancel.sh`         | T9 / T10 / T11                              | `cancel.sh <issue-closed\|label-removed\|pr-closed> <number>` |
| `report-usage.sh`   | Per-run PR usage comment                     | `report-usage.sh <pr> <result-json> <stage>` |

Phase 2's remaining piece is the sweep (M7). The Milestone 3 workflow is
what maps GitHub events to these entry points; Milestone 5 exercises them
end-to-end against a real repo.

The pure decision logic (label resolution, edge parsing, promotable/cycle
computation) is exercised offline by the fixture tests in `tests/` — plain
bash scripts, no gh/network; run them directly.
