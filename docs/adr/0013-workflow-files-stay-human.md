# 0013 — Workflow-file changes are a human class, not an agent one

**Date:** 2026-08-01
**Status:** Accepted

## Context

`ob_manifest_json` scopes the Fixer App to contents / issues / pull-requests
write plus actions read — least privilege, deliberately. GitHub gates any push
that creates or updates `.github/workflows/*` on a **separate** `workflows`
permission, independent of `contents: write`. Such a push is rejected
server-side no matter how good the work is, identically on every retry.

Twice now a full Opus implement turn has been spent discovering this:
mediamtx-connect#214 (2026-07-28) and #306 (2026-08-01), the second while
validating something unrelated. In both, the agent committed clean work and the
push bounced:

```
! [remote rejected] agent/issue-306 (refusing to allow a GitHub App to create or
  update workflow `.github/workflows/ci.yml` without `workflows` permission)
```

The handback is honest — the remote's message reaches the issue and the state
goes to `ready-for-human` on the first attempt rather than stranding until the
watchdog — but the run is a write-off, and the agent has no way to know in
advance.

## Decision

**An issue whose work touches `.github/workflows/*` is not agent-workable.** The
App is not granted `workflows`, and the loop does not try to land such changes;
a maintainer makes them by hand.

Two places carry it, because two different readers need it:

- **The prompts** say it as a capability limit with its reason, and tell the
  agent to STOP and hand back rather than implement the rest. The existing line
  ("Do NOT touch CI configuration, secrets, or unrelated files") read as a scope
  rule about *unrelated* files — #306's issue asked for a CI gate explicitly, so
  the agent reasonably treated it as in scope. Stopping early turns a nine-minute
  turn into a fast, explained handback.
- **`GETTING-STARTED.md`** says it to the maintainer doing triage, who is the
  only one who can keep such an issue out of `ready-for-agent` in the first
  place.

Stopping is deliberate over "do everything except the workflow file": a pull
request that silently omits an acceptance criterion is worse than one that never
opens, because it looks finished.

## Consequences

- A maintenance class — CI changes, new workflows, action bumps in workflow
  files — stays manual for as long as this stands. That is a real reduction in
  what the loop covers, accepted knowingly.
- No agent can rewrite the workflow that runs it, including the one gating its
  own merge. That was already true; it is now true on purpose and written down.
- Existing installs need no re-consent, since the permission set does not change.
- An issue that only *mentions* CI still costs a turn: the guard fires on what
  the work touches, which the agent discovers by doing it. The prompt makes that
  cheap, not free.

## Alternatives

- **Grant `workflows: write`.** The agent could then land CI changes — the thing
  both issues wanted. Rejected: it widens the ADR 0001 boundary to an agent that
  can rewrite the workflow gating its own merge, needs an ADR 0001 addendum and a
  doctor check, and **every existing install must re-consent** — a manifest
  change alone does not migrate them. A maintenance convenience is not worth that
  boundary.
- **Detect it before the agent runs**, from the issue text. Rejected: what the
  work touches is not reliably predictable from what the issue says, and a false
  positive parks work the agent could have done.
- **Leave it as registered debt.** Rejected: the debt entry's payoff trigger was
  "the second consumer issue that needs a workflow-file edit", and #306 was it.

## Payoff trigger

Revisit if the loop is ever asked to maintain a repo whose ordinary work is
mostly workflow files, or if GitHub changes how the `workflows` permission is
granted such that an install can adopt it without re-consent.
