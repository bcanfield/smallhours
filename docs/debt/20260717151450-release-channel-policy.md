---
id: 20260717151450
title: release-channel-policy
principal: 1d
interest: unknown
hotspot: .github/workflows/release.yml
business_capability: release
payoff_trigger: first >=1.0.0 release and first v2 breaking cut
quadrant: prudent-deliberate
category: release
ai_authored: true
created: 2026-07-17
---

release.yml floats a maintainer-declared `v1` channel for 0.x releases rather than deriving the channel strictly from the SemVer major (which for v0.1.0 would be v0). This mirrors ADR 0003 and matches the plan's `@v1` stub and the M1 acceptance wording. The pre-1.0-under-v1 mapping is a deliberate, mild abuse of SemVer's pre-1.0 contract, guarded by a `>=1.0.0 ⇒ channel==v<major>` check so a future v2 cut cannot poison v1 consumers. Revisit at the first >=1.0.0 release and the first breaking v2.
