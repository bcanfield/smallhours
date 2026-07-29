---
id: 20260729120500
title: human-cancel-hands-issue-back
principal: 30m
interest: a maintainer who cancels an implement run to restart it finds the issue in ready-for-human and must relabel to retry
hotspot: .github/workflows/agent-loop.yml
business_capability: dispatch
payoff_trigger: the first time the maintainer cancels a run intending to resume it and is annoyed by the relabel, or when cancel.sh's T10/T11 semantics are next revised
quadrant: prudent-deliberate
category: planning
ai_authored: true
created: 2026-07-29
---

The implement job's `if: cancelled()` step (ADR 0007) sets `ready-for-human` and
comments whenever the job is cancelled. Its purpose is the job-cap case: a
cancelled job runs neither the give-up path nor the diagnostics upload, so
without it the issue holds a `max_concurrent` slot until the sweep watchdog
reclaims it — the threshold plus GitHub's scheduler lag, observed at up to ~65m
against a `*/15` cron.

`cancelled()` cannot distinguish *why*. It also fires when a human cancels the
run from the Actions tab. Handing the issue back in that case was chosen, not
stumbled into: a human who kills an implement run almost always wants it to stop
owning the issue, and the alternative — leaving `agent-working` set with no run
behind it — is the exact stranding this step exists to prevent.

The cost is a small ceremony: cancel-to-restart now takes a relabel back to
`ready-for-agent` rather than just re-triggering. Distinguishing the two causes
is possible (the cancelling actor is on the workflow run via the API) but costs
an API call and a branch in a step that must stay dead simple, because it runs
only when something has already gone wrong.

Note this is a *third* cancellation vocabulary alongside T10 (issue closed
mid-run) and T11 (a human removed `agent-working`), both of which route through
`cancel.sh` with a `sender.type == 'User'` guard. If those semantics are ever
consolidated, this step should be folded in rather than left as a fourth path.
