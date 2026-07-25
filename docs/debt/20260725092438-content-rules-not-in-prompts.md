---
id: 20260725092438
title: content-rules-not-in-prompts
principal: 1h
interest: unknown
hotspot: prompts/implement.md
business_capability: agent-pr-quality
payoff_trigger: next prompt-template revision
quadrant: prudent-deliberate
category: documentation
ai_authored: true
created: 2026-07-25
---

Content rules (anti-bloat authoring guidance) were added to CLAUDE.md but bind interactive sessions only. The unattended agent's prompt templates (prompts/implement.md etc.) were deliberately not extended with an equivalent leanness rule because prompt wording is versioned toolkit behavior and the originating task was docs-only. Agent PRs in consumer repos remain a bloat vector beyond the existing "smallest correct change" rule (gratuitous docs, comments, README additions).
