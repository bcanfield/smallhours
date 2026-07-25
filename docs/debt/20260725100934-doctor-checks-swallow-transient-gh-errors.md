---
id: 20260725100934
title: doctor-checks-swallow-transient-gh-errors
principal: 1h
interest: a transient gh api failure reads as repo drift (false DRIFT DETECTED)
hotspot: setup/doctor.sh
business_capability: planning
payoff_trigger: next false doctor failure, or when doctor gains a scheduled multi-repo audit
quadrant: prudent-inadvertent
category: code_quality
ai_authored: true
created: 2026-07-25
---

Several doctor.sh checks pipe `gh api ... 2>/dev/null` straight into a match (e.g. check_ci greps the workflow list), so a transient gh/API failure is indistinguishable from a genuine missing precondition and reports as drift. Observed live 2026-07-25: doctor said "no active CI workflow found" against mediamtx-connect twice in a row while the CI workflow was active; the identical command passed 5/5 in isolation and the very next doctor run was clean. Fix shape: capture gh output and exit status separately and report "check inconclusive (gh error)" instead of bad, or retry once.
