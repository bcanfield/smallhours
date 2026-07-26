---
id: 20260726124048
title: babysitter-prompt-not-in-repo
principal: 1h
interest: unknown
hotspot: prompts/
business_capability: operations
payoff_trigger: unknown
quadrant: prudent-deliberate
category: documentation
ai_authored: true
created: 2026-07-26
---

The mediamtx rollout babysitter (recurring cloud routine reporting to smallhours#20) carries its operating prompt only inside the routine's job config on claude.ai — drafted in a session scratchpad, never versioned under prompts/. There is no prompt of record in the repo: changing the babysitter's behavior means editing the routine via the claude.ai UI/API, and nothing in-repo shows what the babysitter is instructed to do or nudge (it can fire agent-loop workflow_dispatch ticks). Register a copy under prompts/ or docs/ if the routine becomes load-bearing, or accept the routine config as the single source.
