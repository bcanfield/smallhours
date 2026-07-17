# scripts/ — the portable brains

Every stage transition from `docs/DESIGN.md` lives here as a POSIX-ish bash
script using only `gh` + `jq` — no YAML logic, no Actions-specific state. This
is the self-hosted portability contract (ADR 0001 / ADR 0002): each script must
run locally against a test repo with only `GH_TOKEN` + config env set, so the
same logic can later drive GitLab CI or a self-hosted runner unchanged.

**Populated in Milestone 2.** Planned set (see `docs/IMPLEMENTATION-PLAN.md`):

| Path | Responsibility |
|---|---|
| `lib/config.sh` | Load `.smallhours.yml` + defaults; expose per-stage model / max-turns |
| `lib/state.sh` | Atomic issue-state transitions; enforce exactly-one-state-label; PR marker labels |
| `lib/claude-run.sh` | Sandbox setup + `claude -p --permission-mode acceptEdits` + JSON result capture |
| `authorize.sh` | T1 gate: labeler has write? Fail-closed on deny |
| `implement.sh` | T1: branch `agent/issue-N` (`-rK` on retry), run implement prompt |
| `open-pr.sh` | T1 tail: commits → draft PR; none → `ready-for-human`; branch-but-no-PR fallback |
| `state-manager.sh` | T2 / T3 from CI outcome |
| `address-review.sh` | T7: `changes_requested` from write+ users only |
| `cancel.sh` | T9 / T10 / T11 |
| `report-usage.sh` | Per-run PR usage comment |

Phase 2 adds `auto-fix.sh` (M6) and the sweep (M7).
