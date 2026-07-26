---
id: 20260726101500
title: agent-setup-prompt-not-skill
principal: 1h
interest: none until asked; the paste-prompt must be copied by hand
hotspot: docs/GETTING-STARTED.md
business_capability: onboarding
payoff_trigger: a consumer asks to install setup as a packaged skill (npx skills add / a skills marketplace), or a second agent-facing doc appears
quadrant: prudent-deliberate
category: documentation
ai_authored: true
created: 2026-07-26
---

Agent-driven onboarding is a paste-prompt plus an agent-contract section inside GETTING-STARTED, not a packaged skill (`skills/<name>/SKILL.md`, installable via `npx skills add`, the ego-lite pattern). Chosen because setup runs once per consumer repo — a skill's value is repeated triggering — and a skill thin enough to avoid duplicating the walkthrough would be a pointer the prompt already is. If packaging is ever wanted, extract the contract into `skills/` and keep GETTING-STARTED canonical by linking, so the two cannot drift.
