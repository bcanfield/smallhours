# smallhours

An autonomous issue → PR system: the maintainer grills issues (externally) and
reviews PRs; everything between — implementation, draft PR, state management,
review-feedback revisions, and (Phase 2) CI self-healing — is automated via
Claude Code running unattended in GitHub Actions.

**Status: Milestone 1 complete (toolkit skeleton); Milestone 2 next.** Both
Phase-1 spikes ran green on 2026-07-17 (sandbox egress + reusable-workflow
concurrency). The decisive finding: run the agent as `claude -p
--permission-mode acceptEdits`, **not** `--dangerously-skip-permissions` — the
latter disables the very sandbox meant to contain it (see the ADR 0001
addendum). The toolkit skeleton is now in place: `release.yml` (the sole mover
of the floating `v1` tag — ADR 0003), a callable `agent-loop.yml` skeleton, the
consumer `stub/`, and placeholder `scripts/`, `prompts/`, and `setup/` that name
the milestone filling each. Milestone 2 fills in the portable `scripts/`.

## Reading order

1. [`docs/DESIGN.md`](docs/DESIGN.md) — the agreed system: scope decisions,
   both state machines, every transition and edge-case ruling, security
   posture, phasing.
2. [`CONTEXT.md`](CONTEXT.md) — the vocabulary. Terms are canonical; use them
   exactly.
3. [`docs/IMPLEMENTATION-PLAN.md`](docs/IMPLEMENTATION-PLAN.md) — milestones
   0–7 with acceptance criteria. Milestone 0 is done; start at Milestone 1.
4. [`docs/adr/`](docs/adr/) — the hard-to-reverse decisions and why:
   sandbox-is-the-boundary (0001, **read the spike-0a addendum**),
   packaging/versioning (0002), release semver-channel policy (0003).
5. [`spikes/`](spikes/) — the throwaway Milestone-0 experiments and their
   recorded outcomes; kept as re-runnable regression guards.
6. [`docs/research/packaging-distribution.md`](docs/research/packaging-distribution.md)
   — primary-source citations behind ADR 0002.

## The system in one paragraph

A fully described issue gets the `ready-for-agent` label (the only trigger,
maintainer-applied). A reusable workflow authorizes the labeler, has Claude
Code implement on `agent/issue-N`, and deterministically opens a draft PR.
CI results and formal "Request changes" reviews drive all state transitions;
the issue board always shows exactly one state label per issue, and the PR
board only ever shows "draft, automation's problem" or "ready, maintainer's
move." The human approve+merge is structurally required (branch protection),
and every automation identity is a dedicated GitHub App.
