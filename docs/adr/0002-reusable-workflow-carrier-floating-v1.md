# Reusable workflows carry the logic; floating v1 tag; GHCR image deferred

The toolkit ships as reusable workflows in one public repo, consumed by thin
per-repo stubs (`on:` triggers + permissions + one `uses:@v1` line + secret
wiring — the trigger block structurally cannot be shared on GitHub). Consumers
ride a floating `v1` tag moved only by a release workflow; the GHCR runtime
image is deferred until the GitLab/self-hosted milestone, with tool versions
pinned in a single versions file that will become its Dockerfile input.

## Considered Options

- **Composite action as carrier** (the recommendation in
  `docs/research/packaging-distribution.md`) — rejected: it pushes job-level
  keys the design depends on (per-issue/per-branch `concurrency:` groups, the
  authorize→implement `needs:` split, timeouts) into every stub, where they
  don't upgrade with the tag. A reusable workflow absorbs all of that and
  yields a *thinner* stub. May still be used internally for step reuse.
- **SHA pinning** — rejected while all consumers share one owner: every release
  becomes an N-repo PR chore and repos drift stale. Floating tag risk
  (toolkit-repo compromise = code with every consumer's secrets) is accepted;
  controls are release-workflow-only tag moves and account hardening. Revisit
  if third-party repos ever consume the toolkit.
- **GHCR image from day one** — rejected: on GitHub the sandbox must run on the
  runner VM (bubblewrap is broken/weakened nested in containers; container
  actions cannot add NET_ADMIN), so no GitHub consumer would run the image and
  it would rot unused.

## Consequences

- Job-level `concurrency:` behavior inside called reusable workflows must be
  verified in the Phase 1 spike; fallback is concurrency declared in stubs.
- Stub changes don't propagate (no first-party multi-repo sync); mitigated by
  keeping stubs trigger-only plus a toolkit-owned `update-stubs` script.
- Public consumers require the toolkit repo to be public (public callers can
  only call public reusable workflows).
