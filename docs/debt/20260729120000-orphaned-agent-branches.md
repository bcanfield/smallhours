---
id: 20260729120000
title: orphaned-agent-branches
principal: 2h
interest: consumer remotes accumulate agent/issue-N branches that no PR closes and no sweep prunes, and each retry mints another
hotspot: scripts/implement.sh
business_capability: dispatch
payoff_trigger: a consumer remote where agent/* branches outnumber open agent PRs by more than ~10, or the first time a stale agent branch is mistaken for live work
quadrant: prudent-deliberate
category: architecture
ai_authored: true
created: 2026-07-29
---

ADR 0007 makes a wall-clock give-up push its partial work to `agent/issue-N`
with **no** pull request — deliberately, since a draft PR would start consumer
CI and feed the auto-fix loop a half-implemented change. The branch is the only
artifact a timed-out run leaves, and it is what tells a human what the agent was
actually doing when the clock stopped it.

Nothing ever deletes those branches. A merged PR deletes its own head; a
timeout's branch has no PR, so it survives indefinitely. Retries compound it:
`sweep_next_attempt` mints a fresh `-r2`, `-r3` rather than force-pushing seen
history, so an issue that times out twice leaves two dead refs behind.

A reaper was considered and declined for now — it needs a definition of "safe to
delete" that distinguishes an abandoned timeout branch from one a human is
mid-way through rescuing, and getting that wrong destroys the only copy of work
the system paid for. Deleting nothing is the conservative failure.

Payoff options when it fires: prune in the sweep by age plus "no open PR and the
issue is closed"; or teach `open-pr.sh`'s adopt path to reuse an existing
timeout branch on retry instead of minting a new attempt, which would cap the
litter at one branch per issue.
