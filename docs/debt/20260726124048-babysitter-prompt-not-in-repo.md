---
id: 20260726124048
title: babysitter-prompt-not-in-repo
principal: 1h
interest: the babysitter's own defects cannot be fixed by a change to this repo
hotspot: prompts/
business_capability: operations
payoff_trigger: fired 2026-07-29 — see below; now due whenever the routine's checks are next changed
quadrant: prudent-deliberate
category: documentation
ai_authored: true
created: 2026-07-26
---

The mediamtx rollout babysitter (recurring cloud routine reporting to smallhours#20) carries its operating prompt only inside the routine's job config on claude.ai — drafted in a session scratchpad, never versioned under prompts/. There is no prompt of record in the repo: changing the babysitter's behavior means editing the routine via the claude.ai UI/API, and nothing in-repo shows what the babysitter is instructed to do or nudge (it can fire agent-loop workflow_dispatch ticks). Register a copy under prompts/ or docs/ if the routine becomes load-bearing, or accept the routine config as the single source.

**Trigger fired: the 2026-07-26 → 07-29 rollout (smallhours#20, 27 reports).**
Two defects held for the routine's entire life, and neither is fixable from
this repo — which is the cost this entry was hedging against:

- `doctor.sh` never ran once. The routine's sandbox has no working `gh` auth,
  so every report substituted hand-rolled MCP checks and repeated the same
  caveat — 20+ times. The consequence is not the noise: doctor's actual drift
  coverage (App-install evidence, secret presence, config validation) went
  unexercised across the entire rollout, while the reports read as though the
  board had been fully checked.
- The routine cannot fire a sweep tick. `workflow_dispatch` on `agent-loop.yml`
  returned 403 twice (03:48 and 05:50 on 07-27) against the session's own
  credentials — separate from the Fixer App. The stub gained that manual tick
  precisely *because* the consumer's cron is laggy (M7 note), and the one
  actor meant to use it cannot. Its only remaining lever is asking a human.

Both are prompt/credential facts with no in-repo home, so neither can be
reviewed, tested, or fixed here — which answers the `interest: unknown` this
entry was filed with. Choosing the single source is now the actual work.
