---
id: 20260724233304
title: claude-md-not-agents-md
principal: 15m
interest: unknown
hotspot: CLAUDE.md
business_capability: unknown
payoff_trigger: a non-Claude coding agent (Cursor, Codex, Copilot, etc.) is pointed at this repo
quadrant: prudent-deliberate
category: documentation
ai_authored: true
created: 2026-07-24
---

Agent instructions live in CLAUDE.md directly instead of the cross-tool canonical AGENTS.md with a CLAUDE.md symlink or @AGENTS.md import. Chosen because this repo's only agent is Claude Code today and the user asked for CLAUDE.md specifically. If another coding agent is ever used here, rename to AGENTS.md and make CLAUDE.md an import so the two files can't drift.
