---
id: 20260717223337
title: implement-commits-toolkit-dir
principal: 1h
interest: every agent commit is polluted with the .smallhours-toolkit checkout (gitlink)
hotspot: scripts/implement.sh
business_capability: release
payoff_trigger: BLOCKER — before re-enabling the loop
quadrant: prudent-deliberate
category: code_quality
ai_authored: true
created: 2026-07-17
---

Discovered in M5 dogfooding: agent commits on issue-213/220 included a `.smallhours-toolkit` entry. The reusable workflow checks the toolkit out into `.smallhours-toolkit` inside the consumer working tree (actions/checkout `path` cannot escape GITHUB_WORKSPACE), and implement.sh / address-review.sh run `git add -A`, which stages that nested checkout as a gitlink. Fix: exclude the toolkit dir before `git add` — e.g., the workflow appends `/.smallhours-toolkit/` to `.git/info/exclude` after checkout, or the scripts use a pathspec exclude. Requires a toolkit fix + re-release (move v1).
