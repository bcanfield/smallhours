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
| `config.sh` | Load `.smallhours.yml` over defaults; label vocabulary; per-stage model / max-turns getters |
| `common.sh` | Repo resolution, logging, comments, prompt rendering, linked-issue + branch helpers |
| `state.sh`  | Atomic issue-state transitions (replace, never accumulate) + PR marker labels |
| `claude-run.sh` | Render managed settings from config, provision the sandbox, run a stage under `--permission-mode acceptEdits`, capture JSON. CLI failure = give-up (no retry) |

## Stage scripts

| Script | Transition | Entry point |
|---|---|---|
| `authorize.sh`      | T1 gate (fail-closed on non-write labeller) | `authorize.sh <issue> <actor>` |
| `implement.sh`      | T1 body: branch + implement prompt          | `implement.sh <issue> [attempt]` |
| `open-pr.sh`        | T1 tail: deterministic draft PR / no-commits→human | `open-pr.sh <issue> [branch] [attempt]` |
| `state-manager.sh`  | T2 / T3 from CI outcome                      | `state-manager.sh <pr> <success\|failure>` |
| `address-review.sh` | T7: changes-requested re-summon             | `address-review.sh <pr> <review-state> <reviewer>` |
| `cancel.sh`         | T9 / T10 / T11                              | `cancel.sh <issue-closed\|label-removed\|pr-closed> <number>` |
| `report-usage.sh`   | Per-run PR usage comment                     | `report-usage.sh <pr> <result-json> <stage>` |

Phase 2 adds `auto-fix.sh` (M6) and the sweep (M7). The Milestone 3 workflow is
what maps GitHub events to these entry points; Milestone 5 exercises them
end-to-end against a real repo.
