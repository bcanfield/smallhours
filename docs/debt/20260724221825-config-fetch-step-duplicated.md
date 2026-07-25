---
id: 20260724221825
title: config-fetch-step-duplicated
principal: 2h
interest: unknown
hotspot: .github/workflows/agent-loop.yml
business_capability: dispatch
payoff_trigger: next time the yq/config-fetch step needs a change in all five jobs
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-24
---

The "Install yq + fetch consumer config" step is copy-pasted verbatim into five jobs of agent-loop.yml (dispatch x2, authorize, cancel, ci_state) after 06-1 made those jobs config-dependent for label resolution. GitHub Actions has no lightweight include for steps inside a reusable workflow; a composite action in the toolkit repo would deduplicate it but adds another versioned artifact. Left duplicated for now — any edit to the step must be applied five times or the jobs drift.
