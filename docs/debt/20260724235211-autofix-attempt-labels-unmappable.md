---
id: 20260724235211
title: autofix-attempt-labels-unmappable
principal: 2h
interest: a consumer with a strict label-naming scheme sees raw autofix-attempt-N labels
hotspot: scripts/lib/state.sh
business_capability: release
payoff_trigger: first consumer asks to rename/restyle the attempt labels
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-24
---

The autofix-attempt-N PR labels (T3' consecutive-failure counter, M6) are literal system names deliberately excluded from the .smallhours.yml labels: mapping — the counter is parsed back out of the label name, the set is unbounded (one per attempt up to a configurable attempt_cap), and no workflow gate or human ever references them. lib/state.sh creates them on demand so setup pre-creation is cosmetic only. Consequence: a consumer repo with a strict label-naming scheme cannot rename them the way it can every canonical label.
