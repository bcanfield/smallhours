---
id: 20260724215422
title: decisions-surfaced-not-on-pr
principal: 2h
interest: unknown
hotspot: prompts/implement.md
business_capability: implement
payoff_trigger: first real agent run that reports a Decisions surfaced section and nobody sees it
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-24
---

DESIGN.md's write-boundary row says agent discoveries go in a "Decisions surfaced" PR section. 06-5 instructs the agent to put them under that heading in its final summary, but the summary lives in the result JSON and is only surfaced today on give-up; nothing copies the section onto the PR (report-usage.sh or open-pr.sh would need to extract and post it). Until wired, surfaced decisions are visible only in workflow logs.
