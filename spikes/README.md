# Milestone 0 — Spikes

Throwaway experiments that gate *how* we build, not *whether* (see
`docs/IMPLEMENTATION-PLAN.md`). Each answers one question with evidence, and
each records its outcome as an ADR addendum. **Delete this directory once both
outcomes are recorded** — a spike kept past its answer becomes folklore.

Neither spike's verdict depends on reading logs by eye or on the agent
truthfully reporting its own containment. Both render a machine-checked
pass/fail from artifacts, and both treat *inconclusive* as failure: an unproven
sandbox must never read as a proven one.

## 0a — Sandbox egress on a hosted runner

> **RESOLVED 2026-07-17** (run `29605252082`). Egress *is* containable on
> `ubuntu-24.04`, but **not** with the invocation the plan originally specified.
> `--dangerously-skip-permissions` disables the Bash sandbox (it bypasses the
> permission decision that invokes the bwrap wrapper); `--permission-mode
> acceptEdits` + `sandbox.enabled` + `autoAllowBashIfSandboxed` contains it
> cleanly and stays unattended-safe. bubblewrap works with the required `bwrap`
> AppArmor profile; the iptables fallback was not needed. Full write-up:
> **ADR 0001 addendum**. The workflow is kept as a re-runnable regression guard
> (Probe A must leak, Probe B must contain).

**Question:** can we contain Claude Code's network egress on `ubuntu-latest`,
and which settings keys are actually load-bearing?

```
gh workflow run spike-0a-sandbox.yml -f runner=ubuntu-24.04
```

Needs the `CLAUDE_CODE_OAUTH_TOKEN` repo secret. Runs two profiles side by side:

| Profile | What it is | Expected |
|---|---|---|
| `baseline` | sandbox + allowlist only — the posture the plan literally specifies | may leak; leaks are the finding |
| `hardened` | + the lockdown keys that close documented gaps | contained |

`baseline` is marked `continue-on-error` because a leak there is information,
not a broken build. Only `hardened` failing means we have a real problem.

The run proves, in order: bubblewrap can create user namespaces at all (before
Claude is involved, so a bwrap failure can't be misread as containment); the
version pin held; non-allowlisted egress is blocked; GitHub and Anthropic
egress still works; and whether `WebFetch` bypasses the allowlist.

**Fallback if bubblewrap fails both ways:** the reference `init-firewall.sh`
iptables approach directly on the VM (sudo is available). Per the risk register,
if *both* fail, stop and revisit ADR 0001 with the maintainer — do not ship
allowlist-only.

### Open finding: the sandbox covers the Bash tool only

Anthropic's own settings README states it plainly:

> The `sandbox` property only applies to the `Bash` tool; it does not apply to
> other tools (like Read, Write, WebSearch, WebFetch, MCPs), hooks, or internal
> commands.

ADR 0001 makes the sandbox *the* boundary, so this is worth being precise about.
`sandbox.network.allowedDomains` constrains Bash subprocesses — which is where
the ADR's real threat lives, since running repo tests executes arbitrary repo
code. But two channels sit outside that boundary:

- **`WebFetch`/`WebSearch`** are egress the allowlist never sees. `hardened`
  denies both via `permissions.deny` and pins them shut with
  `allowManagedPermissionRulesOnly`. The spike tests whether that deny actually
  holds under `--dangerously-skip-permissions`.
- **`Write`/`Edit`** bypass `sandbox.filesystem.*`. Under
  `--dangerously-skip-permissions` they are ungated, so the agent can write
  outside the workspace. Blast radius is one ephemeral runner, which is likely
  acceptable — but it should be an accepted risk in the ADR, not an assumed
  non-issue.

Two keys also turn out to be load-bearing in ways worth naming:
`failIfUnavailable` (without it, a missing bubblewrap downgrades to a *warning*
and Claude runs **unsandboxed** — the exact silent failure that would make this
whole design a fiction), and `allowManagedDomainsOnly` (without it, a new domain
*prompts*, and an unattended `-p` run has nobody to prompt).

If `hardened` contains cleanly, the addendum records these keys as mandatory.
If `WebFetch` leaks even under `hardened`, the egress allowlist is not a
boundary and ADR 0001 needs reopening with the maintainer.

`@anthropic-ai/sandbox-runtime` — which wraps the *entire* Claude Code process
rather than just its Bash tool — is the obvious answer if we need one boundary
covering every tool. Out of scope here; noted for the addendum.

## 0b — Concurrency inside a called reusable workflow

> **RESOLVED 2026-07-17.** Runs serialized (`START/END/START/END`, no overlap,
> neither event dropped) with concurrency declared *only* in the called
> workflow. ADR 0002 holds: the group stays behind the tag, stubs stay thin. No
> fallback needed.

**Question:** does job-level `concurrency:` take effect when declared inside a
*called* reusable workflow, or only in the caller?

This is load-bearing for ADR 0002. Reusable workflows beat composite actions as
the carrier precisely because they absorb job-level keys — concurrency groups,
the authorize→implement `needs:` split, timeouts — so those upgrade behind the
floating `v1` tag instead of living in every consumer stub. If concurrency only
works in the caller, every stub grows a per-issue concurrency block that can
never be fixed centrally.

**Both workflows must be on the default branch first** — `issues` events only
ever run default-branch workflows.

```
./spikes/0b/run.sh              # creates a throwaway issue, double-labels, waits, reports
./spikes/0b/verdict.sh <issue>  # re-read the verdict later
```

The caller stub deliberately declares **no** concurrency. If runs serialize
anyway, the called workflow's block is doing the work and ADR 0002 holds.

Evidence lives in the issue's comment log rather than in run logs — deliberately,
per the CONTEXT.md invariant that all loop state lives in GitHub's own
primitives. Serialized runs read `START/END/START/END`; parallel runs read
`START/START/END/END`.

A third outcome matters as much as the two we're testing for: if only **one**
run starts, the second `labeled` event was *dropped* rather than queued. That's
its own finding — a re-labelled issue would silently never get worked — and
`verdict.sh` calls it out rather than folding it into a pass.

**Fallback:** declare concurrency in the stub (the stub-fattening ADR 0002
already anticipates and accepts), recorded as an ADR 0002 addendum.

## Cleanup

```
gh label delete spike-concurrency
rm -rf spikes && git rm -r --cached spikes
```
Then delete `.github/workflows/spike-0*.yml` and close the throwaway issues.
