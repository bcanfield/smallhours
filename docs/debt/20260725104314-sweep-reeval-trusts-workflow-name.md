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

**Payoff trigger fired 2026-07-28 (mediamtx-connect), dodged consumer-side.**
The "loop gains a second gated workflow" half happened for real: the consumer
added `pr-title.yml` (a conventional-commit check) as a workflow separate from
the `CI` workflow smallhours gates on. A red title check could therefore never
trigger auto-fix and never held back the loop's "ready" read — a PR that the
loop reads as green while GitHub refuses to merge it. The consumer resolved it
by folding the check back into `ci.yml`, so the toolkit was not changed and the
weakness is untouched. Keep this open: the fix was one consumer's discipline,
and the next one has no reason to know the rule. Note the trap is worse than
this entry originally framed it — the failure is not only "reads the wrong
signal" but "reads a correct signal that is no longer sufficient", which no
amount of name-matching hardening addresses.
