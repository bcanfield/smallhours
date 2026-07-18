---
id: 20260717215053
title: required-check-autodetect-weak
principal: 2h
interest: onboarding a fresh repo protects without enforcing the CI check unless --required-checks is passed
hotspot: setup/setup-repo.sh
business_capability: release
payoff_trigger: onboarding a repo that has NO ruleset (so setup sets legacy protection) and needs the CI check enforced
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-17
---

When setting legacy branch protection (only when no ruleset exists), setup-repo.sh cannot reliably map required-check contexts: check-run names are job names (e.g. "Build", "E2E Tests"), not the CI workflow name, and check-runs don't carry their workflow name. It degrades to protecting without a required check (never requiring a context that won't report and stranding merges) and lists available check names for the maintainer to pass via --required-checks. For mediamtx-connect this was moot (a ruleset already enforces checks). Revisit if onboarding a rulesetless repo where the CI gate must be auto-enforced.
