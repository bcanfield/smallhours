---
id: 20260730224657
title: conventional-title-map-is-opt-in
principal: 2h
interest: one auto-fix attempt + one CI round trip per unprefixed title, on every consumer that has not set the key
hotspot: scripts/lib/config.sh
business_capability: release
payoff_trigger: a second consumer with a commit-format check is onboarded, or auto_fix is observed retitling on a repo that could have configured the map
quadrant: prudent-deliberate
category: documentation
ai_authored: true
created: 2026-07-30
---

`conventional_title_types` (ADR 0009) is opt-in by presence: a consumer that never sets it keeps paying one auto-fix attempt and one CI round trip for every issue title without a commit-type prefix. That is the correct default — inventing prefixes for a repo that does not use conventional commits would be worse, and the auto_fix retitle path now costs no hand-off — but it means the fix only lands for consumers who read the schema and act.

Nothing surfaces the opportunity: `doctor.sh` does not notice that a repo has a commit-format check and no map, and onboarding does not ask. The cheap payoff is a doctor check that names the key when the consumer's CI has a conventional-commit job; the expensive one is auto-detection, which the ADR deliberately did not do.
