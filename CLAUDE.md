# CLAUDE.md

smallhours is an autonomous issue → PR system: the maintainer grills issues
(externally) and reviews PRs; everything between is Claude Code running
unattended in GitHub Actions.

## Read first, in this order

1. [`docs/DESIGN.md`](docs/DESIGN.md) — the agreed system: scope decisions,
   both state machines, every transition and edge-case ruling, security
   posture, phasing.
2. [`CONTEXT.md`](CONTEXT.md) — the vocabulary. Terms are canonical; use them
   exactly in code, labels, docs, and conversation.
3. [`docs/IMPLEMENTATION-PLAN.md`](docs/IMPLEMENTATION-PLAN.md) — milestones
   with acceptance criteria. The per-milestone DONE annotations there are the
   status of record; don't duplicate status elsewhere.
4. [`docs/adr/`](docs/adr/) — the hard-to-reverse decisions and why. Nothing
   re-litigates a decision: if something can't be built as specified, that's a
   finding to bring back to the maintainer, not a license to redesign.

## Hard rules

- The agent runs as `claude -p --permission-mode acceptEdits` inside the
  managed sandbox. Never use `--dangerously-skip-permissions` — it disables
  the sandbox that is the security boundary (ADR 0001 addendum).
- `release.yml` is the sole mover of the floating `v1` tag (ADR 0003). Never
  move it by hand.
- Read the entries under `docs/debt/` before changing files they reference;
  register new deferred decisions there.

## Repo facts

- `spikes/` are re-runnable regression guards from Milestone 0, not dead code.
- Consumer config schema (`.smallhours.yml`) is specified at the bottom of
  `docs/IMPLEMENTATION-PLAN.md`.
- `versions.env` pins every tool version (ADR 0002); workflows source it
  rather than hardcoding versions.
