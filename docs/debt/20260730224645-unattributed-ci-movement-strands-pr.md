---
id: 20260730224645
title: unattributed-ci-movement-strands-pr
principal: 1d
interest: a ci-failing agent PR can sit unowned until a human notices
hotspot: scripts/auto-fix.sh
business_capability: release
payoff_trigger: a ci-failing agent PR is observed sitting with no owner
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-30
---

auto-fix.sh's clean-tree path (ADR 0009) treats ANY check movement — or any pending check — as "a CI event is coming, so the CI path owns this pull request" and exits 0 without a hand-off. The movement is deliberately not attributed to the agent, because an unrelated check completing mid-run does mean the event path is live. But if the moving check belongs to a workflow the toolkit does not gate on (`config_ci_workflow`), no smallhours event ever fires: the PR sits `ci-failing` with its issue `agent-working` and nothing watching it — `sweep_reeval_pr` only rescues PRs whose latest run is green, and the watchdog only reclaims issues with NO open agent PR.

The 120s re-fire window bounds the risk to the job that caused it, not to the pull request. The rejected alternative was a sweep pass for stranded `ci-failing` PRs, with its own staleness threshold; that is the shape of the payoff. ADR 0009 records this as a knowing residual.
