---
id: 20260717153708
title: phase1-green-not-clean-stranding
principal: 2h
interest: a green PR can sit in draft with no rescue until Phase 2
hotspot: scripts/state-manager.sh
business_capability: release
payoff_trigger: Milestone 7 sweep (T5/T6) lands
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-17
---

state-manager.sh promotes a PR to ready only on CI green AND mergeStateStatus==CLEAN (DESIGN T2). Green-but-not-CLEAN (BEHIND/BLOCKED/DIRTY) leaves the PR a draft, and Phase 1 has no sweep to reconcile it, so it can strand until a human intervenes. This matches the DESIGN spec for Phase 1; the Phase 2 sweep (T5 update-branch / T6 conflict) is what closes the gap. Documented inline.

**Observed live 2026-07-25 (mediamtx-connect PR #247, first full T7 loop):** the T7 path strands STRUCTURALLY, not just on races — the maintainer's changes-requested review keeps reviewDecision=CHANGES_REQUESTED → mergeStateStatus=BLOCKED at the moment the revision's green CI event runs state-manager, so "→ in-review again" can never fire from the CI event alone; a later approval fires no workflow_run to retry. Sweep fix should include: on approved/dismissed review of an agent PR, re-evaluate T2 (the pull_request_review trigger already fires; only a routing job is missing). Manual rescue: approve/dismiss, mark ready, merge.
