---
id: 20260730030000
title: toolkit-tests-never-run-in-ci
principal: 1h
interest: every toolkit test is opt-in on a human remembering to run it locally, so a regression reaches the floating v1 tag with nothing between it and every consumer
hotspot: tests/
business_capability: release
payoff_trigger: the first regression that reaches v1 and is caught by a consumer rather than by the suite, or the next change to release.yml
quadrant: prudent-deliberate
category: process
ai_authored: true
created: 2026-07-30
---

smallhours has nine test suites and 209 assertions, and **no workflow runs any
of them**. `.github/workflows/` holds `agent-loop.yml` (`workflow_call` only —
it never fires on a push or a pull request), `release.yml` (tag-triggered), and
three spike workflows. A pull request against this repo reports no checks
because there are none to report.

That is a sharper gap here than in a normal library, for two reasons specific to
this repo. The tag is floating: `v1` moves on release and every consumer picks
up the change on their next event, with no version pin to shelter behind. And
the maintainer is the only reviewer, so "the tests passed locally" and "the
tests were run at all" are the same claim, made by the same person, unverifiable
afterwards.

The immediate provocation: ADR 0007's preservation bug shipped with a green
suite, because nothing exercised the seam. `tests/test-implement-giveup.sh` now
covers it — and nothing will ever run that file unless someone types its name.

Deliberately not fixed in the same change as the bug it was discovered by. A CI
workflow on the toolkit repo is a new artifact with real questions attached
(does it gate the release, what does it do about the tests that need `git` and
`jq`, does a red suite block the `v1` move), and those are maintainer decisions,
not a rider on a bugfix.

Payoff shape when it fires: a `ci.yml` on `push`/`pull_request` running
`tests/*.sh`, and — the part with actual teeth — a required check on `main` so
the floating tag cannot move over a red suite.
