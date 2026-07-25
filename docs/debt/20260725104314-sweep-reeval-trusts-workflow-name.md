---
id: 20260725104314
title: sweep-reeval-trusts-workflow-name
principal: 2h
interest: a renamed/duplicated CI workflow silently breaks the green gate
hotspot: scripts/lib/sweep.sh
business_capability: release
payoff_trigger: first consumer renames its CI workflow, or the loop gains a second gated workflow
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-25
---

sweep_reeval_pr (used by reeval.sh and the sweep's T2 backstop) decides "CI is green" from the latest completed run of the configured ci_workflow, matched BY NAME via `gh run list --workflow` on the PR head branch. If a consumer renames its CI workflow without updating .smallhours.yml, or two workflows share the display name, the gate silently reads the wrong signal: re-eval either never fires (name matches nothing) or fires on the wrong workflow's conclusion. The workflow_run event path is unaffected (it carries the run identity); only the review-triggered/sweep re-eval trusts the name. Same detection weakness family as required-check-autodetect-weak.
