# 0008 — Let the agent check its own work: expose the sandbox, gate the push

**Date:** 2026-07-29
**Status:** Accepted

## Context

The `implement` job's steps are: app token, two checkouts, `versions.env`,
`consumer-config`, provision the sandbox, run the prompt. There is no
`setup-node`, no `pnpm install`, and no equivalent for any other ecosystem.

`prompts/implement.md` tells the agent to "run the repository's tests/linters to
check your work." **On a repo with dependencies it cannot.** `implement.sh`'s own
give-up text has been saying so all along: *"Nothing on that branch has been
reviewed or tested."*

So the loop was: write blind → push → wait for CI → maybe spend one of only
`attempt_cap` auto-fix attempts → repeat. Measured on the mediamtx-connect
consumer, CI takes **3m18s**; the checks an agent could have run locally take
**8.5s**. A missing import cost a full round trip and a third of the repair
budget.

### Why the missing piece was smaller than it looked

The instinct was to build a setup phase, which is what comparable products do —
GitHub Copilot's coding agent runs `.github/workflows/copilot-setup-steps.yml`
before the agent starts, and OpenAI's Codex runs a setup script with network
access before an otherwise air-gapped agent phase. Both are two-phase for exactly
our reason: Copilot's docs note the agent *can* discover dependencies by trial and
error, but that this is "slow and unreliable, given the non-deterministic nature
of large language models."

Reading Claude Code's own sandbox documentation first changed the diagnosis. The
toolkit already renders a well-hardened profile — `failIfUnavailable`,
`allowUnsandboxedCommands: false`, `allowManagedDomainsOnly`,
`allowLocalBinding: false`, `WebFetch`/`WebSearch` denied. Isolation and egress
were never ours to build; they are Claude Code features, already configured.

What was actually blocking installation was one line of the sandbox contract:
**writes are permitted to the working directory and `$TMPDIR` only.** A package
store lives outside both. `npm_allowed: true` granted the registry and nothing
else, so an install would resolve and then fail to write — a confusing
half-failure, and the only reason a setup phase looked mandatory.

### What a setup phase would actually buy, measured

On the mediamtx-connect consumer:

| install | wall |
|---|---|
| cold, empty store — what an in-sandbox agent gets | **21.4s** |
| warm store — what `actions/cache` would give a setup phase | **8.1s** |

**~13 seconds.** Not the load-bearing difference it was assumed to be. A setup
phase also buys toolchain pinning, install cost charged to the job rather than the
agent's wall-clock budget, and failures visible in job logs instead of a
transcript — real but secondary, and all purchasable later.

## Decision

Expose the sandbox instead of inventing a phase, and gate the push.

### 1. A `sandbox:` key in `.smallhours.yml`, additive and arrays-only

Consumers may append to `filesystem.allowWrite` / `allowRead` / `denyWrite` /
`denyRead`, `excludedCommands`, `credentials.files` / `envVars`, and
`network.allowedDomains`. That is enough for the package-store writes an install
needs, in any ecosystem, without the toolkit knowing what a package store is.

Enforced as a **whitelist, not a deny-list**: a key Claude Code adds upstream is
inert here until someone adds it deliberately. A deny-list would admit every
future key — including one that weakens the profile — until noticed.

`enabled`, `failIfUnavailable`, `allowUnsandboxedCommands`,
`allowManagedDomainsOnly`, `filesystem.disabled`, `enableWeakerNestedSandbox` and
the Unix-socket keys stay toolkit-owned. This matters more than it looks:
`.smallhours.yml` is rendered into **managed** settings, which is precisely the
scope Claude Code trusts to override a hardened profile. A naive passthrough would
let a repo dissolve its own agent's boundary from the inside. Setting one logs a
warning and is ignored — silence would let a consumer believe it took effect.

The agent can edit `.smallhours.yml`, but not to its own benefit: settings are
rendered from the checkout *before* Claude starts, so a widening it writes lands
in a pull request for review and only affects later runs.

### 2. A `verify:` gate with bounded re-entry

Any shell command; the toolkit reads only its exit status. It runs after the agent
phase and before the PR exists. On failure the agent **re-enters** — `claude -p
--continue`, resuming the same session with the command's output — up to
`verify_reentries` times (default 2).

Resuming rather than starting fresh is deliberate. A cold agent handed a stack
trace has to re-derive what the change was for, and the cheapest way to green a
gate it does not understand is to revert the work or delete the check. A resumed
session already holds the change; the prompt also says not to do either.

**The gate never fails the run.** Still red after its re-entries, the branch is
pushed anyway and the PR body carries the command, its exit status and the tail of
its output. The gate can make the loop faster; it cannot make it stricter, and it
cannot strand an issue that would otherwise have reached review. CI and auto-fix
remain exactly the backstop they were.

Re-entry is its own word because the system now has three loops and they must stay
distinguishable: an **attempt** is a CI auto-fix across jobs, a **re-summon** is a
requested-changes review across stages, a **re-entry** is inside one job
(CONTEXT.md).

### 3. No setup phase

Consumers document `install` in their own `AGENTS.md`; the agent runs it as its
first action and pays ~21s once per job. Revisit if that proves unreliable rather
than assuming it will.

Everything above is **additive and default-off**. No `sandbox:` key renders
byte-identical settings to before — asserted in `tests/test-sandbox-config.sh` —
and no `verify:` key means no gate. Consumers pin `@v1`; none of them change
behaviour until they opt in.

## Consequences

- An agent on a configured consumer can run the repo's own checks, so the first
  signal on a lint or type error moves from ~3m18s to ~8.5s and costs no
  `attempt_cap` attempt. That budget is left for real integration failures.
- `attempt_cap` becomes a meaningful ceiling on *CI* failures rather than one
  partly spent on typos.
- **The gate is only as good as what the consumer's command covers.** A repo whose
  fast checks miss most of its behaviour gets a gate that passes on broken work.
  That is the consumer's problem to fix, but the toolkit should not imply
  otherwise.
- **`npm_allowed: true` now means the agent can install packages mid-task**, which
  is a real widening: it can add a dependency an issue calls for, and it reaches a
  host that is neither GitHub nor Anthropic. Bounded by it being opt-in per repo,
  by `NPM_CONFIG_IGNORE_SCRIPTS`, and by whatever the consumer's own lockfile
  policy enforces.
- **Re-entry costs Claude invocations.** A permanently red gate spends
  `verify_reentries` extra runs before pushing. Bounded, and each is cheap
  relative to a CI round trip, but it is not free.
- Re-entry usage is **not** reported. `report-usage.sh` reads the stage's result
  JSON and re-entries write their own files, so the PR's usage figures cover the
  implement run only. Deliberate: overwriting would replace real implement data
  with a repair's, which is worse than omitting it.
- A consumer *can* weaken its own agent's sandbox through `excludedCommands`. The
  threat model this profile defends against is a prompt-injected agent, not a
  hostile maintainer — who already owns the repo — and `.smallhours.yml` changes
  are reviewable.
- One more config surface to document, and the sandbox whitelist has to be
  extended by hand when a consumer needs a key it does not yet cover.

## Alternatives

- **Build a setup phase** (a `.smallhours/setup` composite action run before
  provisioning, the Copilot/Codex shape). Rejected as the *first* move on the
  measurement: it buys ~13s plus determinism over letting the agent install
  itself, and it is a mechanism, a conditional-`uses:` behaviour to verify, and
  consumer docs. Genuinely reconsider if in-sandbox installs prove flaky, if
  toolchain pinning bites, or if 21.4s grows.
- **Raw `sandbox:` passthrough with a deny-list.** Most future-proof — new Claude
  Code keys work with no toolkit release. Rejected: it fails *open*. A key added
  upstream that weakens the profile would be permitted by default until someone
  noticed, and this profile is the whole security story of ADR 0001.
- **Named keys, one per need** (`sandbox_allow_write:`, …), matching today's
  `egress_extra_domains` style. Most reviewable, but every new sandbox capability
  needs a toolkit release to surface, and the loop is meant to be language-neutral.
- **Make `npm_allowed` also render the store paths.** Zero new config surface and
  it solves today's actual need. Rejected as npm-specific in a toolkit that is
  not: Cargo, pip and Go consumers hit the identical wall the following week.
- **Prebuilt container image with dependencies baked in.** Takes install to ~0s.
  Rejected: an image to build, publish and keep in sync with every consumer's
  lockfile, and a stale image is silently-wrong dependencies — a green run against
  the wrong tree.
- **No gate; just tell the agent to run the checks.** Zero machinery, and once
  installation works the agent probably will. Rejected on the same grounds as the
  rest of this system: a self-report is not a check. The prompt asks *and* the
  toolkit verifies.
- **Route a red gate to `ready-for-human`.** Strictest — nothing red reaches CI.
  Rejected: it converts a trailing-comma error into a human interrupt, and hands
  off failures the auto-fix stage repairs routinely with fresh context.

## Payoff trigger

Build the setup phase when any of: in-sandbox installs fail often enough to show
up in give-ups; a consumer needs a pinned toolchain the runner does not carry;
cold install passes ~60s; or install time starts eating enough of the wall-clock
budget to cause `error_timeout` give-ups. Revisit the sandbox whitelist whenever a
consumer asks for a key it does not cover — including `allowLocalBinding`, which
a consumer whose checks bind a port will need and which is toolkit-owned today.
