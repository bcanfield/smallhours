# smallhours

An autonomous issue → PR system: the maintainer grills issues (externally) and
reviews PRs; everything between — implementation, draft PR, state management,
review-feedback revisions, and (Phase 2) CI self-healing — is automated via
Claude Code running unattended in GitHub Actions.

**Status: design complete, pre-build.** No implementation exists yet.

## Reading order

1. [`docs/DESIGN.md`](docs/DESIGN.md) — the agreed system: scope decisions,
   both state machines, every transition and edge-case ruling, security
   posture, phasing.
2. [`CONTEXT.md`](CONTEXT.md) — the vocabulary. Terms are canonical; use them
   exactly.
3. [`docs/IMPLEMENTATION-PLAN.md`](docs/IMPLEMENTATION-PLAN.md) — milestones
   0–7 with acceptance criteria. Start at Milestone 0 (two spikes).
4. [`docs/adr/`](docs/adr/) — the two hard-to-reverse decisions and why:
   sandbox-is-the-boundary (0001), packaging/versioning (0002).
5. [`docs/research/packaging-distribution.md`](docs/research/packaging-distribution.md)
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
