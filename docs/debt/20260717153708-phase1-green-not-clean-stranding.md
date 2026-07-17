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
