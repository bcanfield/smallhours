# prompts/ — per-stage prompt templates

One template per Claude Code stage. Kept out of the scripts so prompt wording
can be reviewed and iterated without touching control flow, and so the same
templates are reusable by a future non-Actions runtime.

Each template carries a lone `{{CONTEXT}}` line; the calling script splices the
issue/PR context in there verbatim (`sh_render_prompt`), so arbitrary issue text
is never interpreted as shell or regex. Templates never fetch context themselves.

| Template | Stage | Status |
|---|---|---|
| `implement.md`       | build the fully-described issue on `agent/issue-N` | ✅ Milestone 2 |
| `address-review.md`  | apply a formal "Request changes" review            | ✅ Milestone 2 |
| `auto-fix.md`        | repair red CI on an `agent`-labelled PR            | ✅ Milestone 6 |
| `resolve-conflict.md`| resolve a DIRTY branch                             | Phase 2 (M7) |
