---
id: 20260729000000
title: fixer-app-cannot-push-workflows
principal: 2h
interest: any issue whose acceptance criteria edits .github/workflows/* is unlandable, and only discovers this after a full implement turn
hotspot: scripts/lib/onboarding.sh
business_capability: dispatch
payoff_trigger: the second consumer issue that needs a workflow-file edit, or the next revision of the Fixer permission set
quadrant: prudent-deliberate
category: architecture
ai_authored: true
created: 2026-07-29
---

`ob_manifest_json` scopes the Fixer App to contents/issues/pull-requests write
+ actions read (least privilege, deliberate). GitHub gates any push touching
`.github/workflows/*` on a SEPARATE `workflows` permission, independent of
`contents: write` — so such a push is rejected server-side no matter how good
the agent's work is. This is not a flake: it fails identically on every retry,
and the agent cannot know in advance.

Observed on mediamtx-connect#214 (2026-07-28), whose acceptance criteria
included a FEATURES.md CI gate in `ci.yml`: a full Opus implement turn (41
bash, 18 edits, 15 files) committed cleanly, then the push was rejected. The
give-up-on-push handling that failure exposed is fixed (smallhours#24); this
entry is the structural half, which is a maintainer call, not a bug.

The fork, deliberately not decided here:

- **Grant `workflows: write`.** The agent can then land CI changes — the
  thing #214 wanted. Costs: it widens the ADR 0001 boundary (an agent that
  can rewrite the workflow that runs it, including the one gating its own
  merge), needs an ADR 0001 addendum, needs a doctor check, and every EXISTING
  install must re-consent — a manifest change alone does not migrate them.
- **Declare it unsupported.** Triage flags "touches `.github/workflows/*`" as
  a precondition before promotion, so the issue never reaches implement and
  the turn is never burned. Costs: a whole class of maintenance work stays
  manual forever, and the precondition needs somewhere to live that triage
  actually reads.

Until one is chosen, the failure mode is at least diagnosable: the push
rejection now posts its remote message to the issue and hands back to
`ready-for-human` on the first attempt instead of stranding until the watchdog.
