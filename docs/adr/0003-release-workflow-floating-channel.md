# 0003 — release.yml cuts immutable semver; floats a declared major channel

**Date:** 2026-07-17
**Status:** Accepted

## Context

ADR 0002 fixed the distribution model: consumers pin
`uses: …/agent-loop.yml@v1`, and a floating `v1` tag is moved only by a release
workflow; breaking changes cut `v2`. Milestone 1 must implement that workflow.

Its acceptance criterion is: "release.yml cuts `v0.1.0` and moves `v1`." That
sentence hides a tension. Under strict SemVer, `v0.1.0`'s major is `0`, so a
workflow that floats `v<major>` would move `v0`, not `v1`. But the stub, ADR
0002, and the acceptance criterion all say consumers ride `@v1` from the first
release. So the floating tag cannot be a pure function of the release's SemVer
major during the pre-1.0 period.

## Decision

`release.yml` (`workflow_dispatch`) takes two inputs: an immutable `version`
(`vX.Y.Z`) and a floating `channel` (`v<N>`, default `v1`). It:

1. validates both formats;
2. for releases `>= 1.0.0`, **requires** `channel == v<major>` (a v2.3.0 cut can
   only float `v2`) — this closes the obvious footgun;
3. for `0.x` releases, allows any `channel` (default `v1`), treating `0.x` as
   pre-stable *within* the v1 line;
4. refuses to re-cut an existing `version` tag (SemVer tags are immutable);
5. creates the annotated `version` tag, force-moves `channel` to it, and
   publishes a GitHub Release.

It runs on the default `GITHUB_TOKEN` with `contents: write` — a release tag
never needs to re-trigger CI, so the Fixer App identity (ADR 0001) is not used.

## Consequences

- Consumers pin `@v1` from `v0.1.0` onward, exactly as the stub and ADR 0002
  assume. The `@v1` pin is semi-permanent, so the channel choice is hard to
  reverse for anyone already onboarded.
- `0.x` under a `v1` channel is a deliberate, mild abuse of SemVer's pre-1.0
  contract: `0.x` still signals "no stability promise", but the *pin* is stable.
- One entry point moves the tag, preserving ADR 0002's control on the accepted
  floating-tag compromise risk. The `>=1.0.0 ⇒ channel==v<major>` guard means a
  future `v2` cut cannot silently poison `v1` consumers.

## Alternatives

- **Strict SemVer major channel** — float `v<major>` always; `v0.1.0` → `v0`,
  consumers pin `@v0` until `v1.0.0`. Honours SemVer precisely but contradicts
  the plan's `@v1` stub and the M1 acceptance wording, and forces every early
  consumer to re-pin at first stable release. Rejected.
- **Hardcode `v1` in the workflow** — simplest, but needs an edit (and a missed
  edit is a silent mis-float) when `v2` arrives. Rejected in favour of the
  validated `channel` input.

## Payoff trigger

Revisit when cutting the first `>= 1.0.0` release, or the first `v2` (breaking)
release — confirm the `channel` guard behaves and that `v1` consumers are not
dragged onto `v2`.
