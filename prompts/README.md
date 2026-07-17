# prompts/ — per-stage prompt templates

One template per Claude Code stage. Kept out of the scripts so prompt wording
can be reviewed and iterated without touching control flow, and so the same
templates are reusable by a future non-Actions runtime.

**Populated in Milestone 2 / Milestone 3.** Planned templates (one per stage in
`docs/DESIGN.md` "Stage configuration"):

- `implement` — build the fully-described issue on `agent/issue-N`.
- `address-review` — apply a formal "Request changes" review.
- `auto-fix` (Phase 2) — repair red CI on an `agent`-labelled PR.
- `resolve-conflict` (Phase 2) — resolve a DIRTY branch.

Each template receives issue/PR context from the calling script (Milestone 2),
never fetches it itself.
