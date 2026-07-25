---
id: 20260724235220
title: autofix-log-context-needs-actions-read
principal: 2h
interest: auto-fix runs blind (check names only) on repos whose App lacks Actions read
hotspot: scripts/auto-fix.sh
business_capability: release
payoff_trigger: first auto-fix give-up whose summary shows it could not see the failure logs
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-24
---

auto-fix.sh enriches the prompt with `gh run view --log-failed`, which needs the Fixer App to hold Actions read permission on the consumer repo. If the permission is absent the enrichment degrades silently to failing-check names plus an in-prompt hint to reproduce locally (enrichment never fails the run, same posture as tracker-context). doctor.sh's App-permission check covers issues:write but does not check Actions read, so the degraded mode is invisible until someone reads an agent summary.
