---
id: 20260731120000
title: verify-first-token-heuristic
principal: 1h
interest: a consumer whose verify command starts with an assignment or a builtin still burns a Claude stage on an environment fault the gate could have named
hotspot: scripts/lib/verify.sh
business_capability: verify-gate
payoff_trigger: the first consumer observed losing a stage to a 127 the first-token test failed to classify
quadrant: prudent-deliberate
category: architecture
ai_authored: true
created: 2026-07-31
---

ADR 0011 decision 2 tells "the gate never started" from "something the gate ran
was missing" by comparing the executable bash reported as not found against the
**first whitespace-delimited word** of the configured `verify:` command.

That is deliberately narrow and deliberately biased toward re-entering. It misses:

- `FOO=1 pnpm verify` — first token is the assignment, so a missing `pnpm` reads
  as a nested failure and costs a re-entry.
- `cd packages/app && make test` — first token is a builtin; a missing `make`
  reads the same way.
- any command whose real entry point is behind a shell operator.

Each miss costs exactly what the old behaviour cost — one Claude stage — so this
is a smaller improvement in those shapes, never a regression. The conservative
direction was chosen because the opposite error is worse: classifying a
genuinely fixable 127 as environmental abandons work the agent could have
finished.

The honest fix is to ask the shell instead of parsing the string: resolve the
command's actual entry point in the same initialised shell (`type -t`,
`command -v`) before running it, and compare that. It needs care around
compound commands and is more machinery than the observed failure justified.

Not urgent: `pnpm verify`, `npm run x`, `make check` and `just test` — the shapes
consumers actually write — all classify correctly today.
