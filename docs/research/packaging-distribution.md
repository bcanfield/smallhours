# Packaging & distribution of the CI automation toolkit

How to package and version this toolkit so 5–20 public repos can consume it
without copy-paste, and so the same logic can later run on GitLab CI and
self-hosted hardware.

The toolkit has two halves that package differently:

- **(a) Orchestration logic** — shell/CLI that drives `gh`, `glab`, and the
  Claude Code CLI (`claude -p`), inside a sandbox (bubblewrap, or an iptables
  egress firewall needing `NET_ADMIN`).
- **(b) Workflow definitions** — the GitHub Actions YAML implementing the
  issue→PR loop (triggers: `issues` labeled, `workflow_run`,
  `pull_request_review`, `schedule`).

No single mechanism packages both halves. The verified conclusion (see
[Recommended architecture](#recommended-architecture)): distribute half (a) as a
**versioned composite action** (portable to a container image later), keep half
(b) as a **thin per-repo caller stub** that GitHub structurally requires, and
treat a **GHCR image** as the portability substrate for GitLab/self-hosted.

Every claim below is tagged to the primary doc that owns it. Claims I could not
confirm against a primary source are tagged **UNVERIFIED**.

---

## Option 1 — GitHub reusable workflows

A reusable workflow is a whole workflow (jobs + steps) called from another
workflow via `jobs.<id>.uses:`.

**Cross-repo referencing & access.** Reference syntax is
`{owner}/{repo}/.github/workflows/{file}@{ref}`; same-repo calls use
`./.github/workflows/{file}` with no ref. A **public** repo's caller can only
call reusable workflows stored in **public** repositories; private/internal
reusable workflows are callable by other repos only when that repo's Actions
access settings explicitly allow it.
[[reusing-workflow-configurations]], [[reuse-workflows]]

**Versioning.** Ref may be a **commit SHA, release tag, or branch**. "Using the
commit SHA is the safest option for stability and security." "If a release tag
and a branch have the same name, the release tag takes precedence over the
branch name." A floating tag (e.g. `@v1`) works exactly like the `actions/*`
pattern — moving the tag repoints every consumer on their next run (no
per-consumer action needed), which is the low-friction upgrade lever but also
means an unpinned consumer inherits changes immediately. [[reuse-workflows]]

**Limits (verified numbers).**
- Nesting: "You can connect a maximum of ten levels of workflows" (top-level
  caller + up to nine nested). Loops are not permitted.
- "You can call a maximum of **50** unique reusable workflows from a single
  workflow file." [[reusing-workflow-configurations]]

**Event context — the load-bearing constraint.** A reusable workflow **cannot
be triggered directly** by `issues`, `pull_request_review`, `workflow_run`, or
`schedule`; its `on:` "must include `workflow_call`." It only runs when a caller
invokes it. **But** "When a reusable workflow is triggered by a caller workflow,
the `github` context is always associated with the caller workflow." So the
reusable workflow *does* see the caller's `github.event` (the labeled issue, the
review, etc.) — the trigger must live in the caller, but the event payload flows
through. [[reuse-workflows]], [[reusing-workflow-configurations]]

Consequence: **the `on:` trigger block must physically live in each consumer
repo.** Reusable workflows do not remove the per-repo file; they shrink it to a
caller stub (see [stub](#what-the-consumer-repo-stub-looks-like)).

**Secrets.** A caller in the same org/enterprise can pass all its secrets with
`secrets: inherit`. Secrets propagate only through direct calls — in A→B→C, C
gets secrets only if A→B and B→C each pass them. [[reuse-workflows]]
**Note:** `secrets: inherit` is scoped to the same org/enterprise; it is not a
general cross-owner mechanism. For public single-maintainer repos under one
account this is fine, but a fork/other-owner consumer must pass secrets
explicitly.

**Env gotcha.** "Any environment variables set in an `env` context defined at
the workflow level in the caller workflow are **not** propagated to the called
workflow." Pass config as `with:` inputs, not `env`. [[reusing-workflow-configurations]]

---

## Option 2 — Composite actions

A composite action bundles a series of **steps** into a single step
(`action.yml` with `runs.using: "composite"`), runnable inside any job.

**What it can do.** Run shell (`run:` + `shell:`), call other actions, take
`inputs`, expose `outputs`. It is referenced like any action:
`uses: owner/repo@ref` cross-repo, or `uses: ./path` same-repo — same
tag/SHA/branch versioning story as Option 1. [[creating-a-composite-action]]

**What it cannot do.** It has **no `on:` triggers and defines no jobs** — it is
steps only. It also cannot set job-level keys the caller job owns: `container:`,
`permissions:`, `strategy:`, `runs-on:`. GitHub's own comparison: reusable
workflows "reuse an entire workflow with multiple jobs," whereas composite
actions "combine multiple steps that you can then run within a job step."
Reusable workflows "can use secrets"; composite actions "cannot use secrets" as
a first-class key — secrets reach a composite action only as explicit `inputs`.
[[creating-a-composite-action]], [[reusing-workflow-configurations]]

**When it's the better fit.** When the *reusable unit is a body of steps* (clone
toolkit, install `gh`/`glab`/`claude`, set up the sandbox, run the orchestration
script) that always executes inside a job whose triggers, `runs-on`, and
`permissions` the consumer already declares. That is exactly half (a) of this
toolkit. The consumer's caller workflow owns the `issues: labeled` trigger and
the `permissions` block; the composite action owns "everything that happens once
we're running." This keeps the per-repo stub thin while giving the toolkit full
control of the step sequence.

---

## Option 3 — Docker image on GHCR

Bundle scripts + `claude` + `gh` + `glab` into one image on `ghcr.io`.

**Three consumption modes.**
1. GitHub Actions **container job** (`jobs.<id>.container.image:`) or a Docker
   container action.
2. GitLab CI `image:`.
3. `docker run` on self-hosted hardware.

**GHCR auth.** From GitHub Actions, log in with the built-in `GITHUB_TOKEN` and a
job `permissions: packages: write` (or `read` to pull); the documented pattern
is `echo $TOKEN | docker login ghcr.io -u USERNAME --password-stdin`. **Public
images can be pulled anonymously** ("You can also access public container images
anonymously") — so GitLab/self-hosted pulls of a public image need no
credentials. From outside GitHub (e.g. GitLab pushing), authenticate with a PAT
carrying `read:packages`/`write:packages`. [[working-with-the-container-registry]]

**NET_ADMIN — the decisive finding.** There are two different container paths
with **different** capability rules:

- **Docker container *actions*** (`runs.using: docker` in an `action.yml`):
  "GitHub Actions supports the default Linux capabilities that Docker supports.
  **Capabilities can't be added or removed.**" So a container action **cannot**
  get `NET_ADMIN` → the iptables-firewall sandbox **cannot** run this way.
  [[dockerfile-support]]
- **Container *jobs*** (`jobs.<id>.container` with `options:`): `options` passes
  through to `docker create`; the docs state only that "The `--network` and
  `--entrypoint` options are **not supported**." `--cap-add=NET_ADMIN` is *not*
  on the documented unsupported list. [[run-jobs-in-a-container]]
  **UNVERIFIED:** whether `container.options: --cap-add=NET_ADMIN` is actually
  honored on GitHub-**hosted** runners — no primary doc confirms hosted-runner
  container jobs grant added capabilities, and the capabilities prohibition on
  the container-*actions* page suggests the hosted Docker daemon may reject it.
  Do not design around this without an empirical spike.

**Bubblewrap inside Docker — verified constraint.** Claude Code's own sandbox
docs state it plainly: "**Bubblewrap fails to start inside a container:** in an
unprivileged container, bubblewrap cannot mount a fresh `/proc` filesystem." The
workaround (`enableWeakerNestedSandbox`) "enables it to work inside Docker
environments without privileged namespaces … This option considerably weakens
security and should only be used when additional isolation is otherwise
enforced." Separately, on Ubuntu 24.04+ the default AppArmor policy "prevents
bubblewrap from creating the user namespaces it needs" and requires a custom
`bwrap` AppArmor profile. [[claude-code-sandboxing]]

So **running bwrap nested inside a GitHub Actions container job is a weakened
sandbox at best.** By contrast, on a standard (non-container) GitHub-hosted
runner the job runs directly on the VM with passwordless sudo, where bubblewrap
and iptables both work normally — which is why the toolkit's sandbox belongs on
the runner VM, not inside a container job, on GitHub.

**Root/`--dangerously-skip-permissions` note.** Claude Code blocks
`--dangerously-skip-permissions` when running as root, except "inside a
recognized sandbox"; for autonomous container use the docs point at the dev
container config "which runs Claude Code as a non-root user." Relevant when the
image path is used later. [[claude-code-sandboxing]]

**Where the image shines.** It is the **portability substrate**: the *same*
image is `container:` on GitHub, `image:` on GitLab, and `docker run` on
self-hosted — one artifact, three runtimes. Its weakness is precisely the
sandbox-nesting problem above, so on GitHub the image is better used to pin the
*tool versions* (a base others build on) than to host the sandbox.

---

## Option 4 — npm package with a CLI (npx)

Publish the orchestration CLI to npm; invoke as `npx pkg@version …` in any CI.

**Facts.** `npx` runs a package's `bin`; "If any requested packages are not
present in the local project dependencies, then they are installed to a folder
in the npm cache." Pin with `npx pkg@1.2.3` or `npx -- <pkg>[@<version>]`.
[[npx]] Public vs private is standard npm registry scoping.

**Assessment.** npm/npx cleanly versions and distributes **half (a)** and is
genuinely CI-agnostic (works identically on GitHub, GitLab, self-hosted). Its
costs: a cold `npx` fetches+caches the package each fresh runner (network + a few
seconds), and it pulls a Node runtime into the dependency surface. Crucially it
**does nothing for half (b)** — the workflow YAML and its triggers still have to
exist per repo. It also doesn't solve tool bundling (`gh`, `glab`, `claude`
still need installing). It's a viable *alternative* to a composite action for
shipping the CLI, but for this toolkit a composite action is a better home
because the reusable unit is really "steps that install tools + set up sandbox +
run," not just "one Node CLI." Keep npx in reserve if the orchestration logic
consolidates into a single portable Node binary.

**Note:** Claude Code itself installs via `npm i -g @anthropic-ai/claude-code`
**or** the native installer `curl -fsSL https://claude.ai/install.sh | bash`
(pin with `| bash -s 2.1.89`); the npm package just fetches the same native
binary. This is about installing the *dependency*, not packaging *our* toolkit.
[[claude-code-setup]]

---

## Option 5 — GitLab side (the "later" path)

**CI/CD components** are the GitLab analogue of reusable workflows/composite
actions: "a reusable single pipeline configuration unit." Included via
`include: - component: $CI_SERVER_FQDN/<project-path>/<component-name>@<version>`
with `inputs:`. Versioning: commit SHA, tag (semver required for catalog),
branch, or `~latest`/partial-semver for catalog components. They can be shared
across projects and published to the **CI/CD Catalog**. **GA since GitLab 17.0.**
[[gitlab-components]]

**Plain `include:`** offers `local`, `project`, `remote`, `template`, and
`component`. `include: project:` supports a `ref:` (tag/branch/SHA) for real
version pinning across projects; `include: remote:` fetches a URL but **does not
support version pinning** — you get whatever is at the URL now. So for versioned
cross-project reuse on GitLab, use **components** or `include: project` with a
`ref`, not `include: remote`. [[gitlab-includes]]

**Triggers — GitLab has no native `issues:labeled`/`workflow_run` equivalent.**
GitLab pipelines are triggered by git events, schedules, the API, or upstream
pipelines — **not** by issue-label changes or review submissions. The
issue→PR(MR) loop's entry points map as follows:
- `issues: labeled` / `pull_request_review` → **no native trigger.** Use a
  **project/group webhook** (issue events, merge-request events) pointed at an
  external receiver that calls the **pipeline trigger API**
  (`POST /projects/:id/trigger/pipeline` with a trigger token). Webhooks
  *notify*; they do not themselves start pipelines. [[gitlab-triggers]]
- `workflow_run` (chain off another run) → **upstream/multi-project pipeline**
  relationships (`needs:pipeline`/`trigger:`). **UNVERIFIED** here (not fetched);
  confirm against GitLab parent-child/multi-project pipeline docs before relying
  on it.
- `schedule` → **pipeline schedules** (cron). Native. **UNVERIFIED** exact
  behavior here (the triggers page focused on trigger tokens); confirm against
  GitLab "Pipeline schedules" doc.

This confirms the CONTEXT.md invariant already anticipates the hard part: **all
loop state lives in GitHub/GitLab primitives (labels, draft/WIP status,
comments), never runner-local state**, because the GitLab port must reconstruct
the same state machine from a webhook + trigger-API bridge rather than rich
native events.

---

## Comparison

| Option | Ships half (a) logic? | Ships half (b) triggers? | Versioning | Cross-repo (public) | Portable to GitLab/self-hosted? | NET_ADMIN / bwrap sandbox |
|---|---|---|---|---|---|---|
| Reusable workflow | Yes (as jobs) | **No** — caller still needs `on:` | tag/SHA/branch, floating `@v1` | public→public only | No (GitHub-only YAML) | Runs on runner VM (sandbox OK) |
| **Composite action** | **Yes (as steps)** | No — caller owns trigger + `permissions` | tag/SHA/branch, floating `@v1` | public→public | No (GitHub-only), but logic re-usable | **Runs on runner VM → bwrap/iptables work** |
| GHCR image | Yes (bundled tools) | No | image tag / digest | anon pull if public | **Yes — one artifact, 3 runtimes** | bwrap nested = weakened; NET_ADMIN in container job UNVERIFIED |
| npm/npx CLI | Yes (if consolidated) | No | `pkg@x.y.z` | public/private registry | Yes (CI-agnostic) | Depends on where npx runs (VM = OK) |
| GitLab component | (later) Yes | Partial (git/schedule triggers) | tag/SHA/branch/`~latest` | catalog / project ref | GitLab-native | Runner-dependent |

Recurring truth in every row: **no mechanism ships the `on:` triggers for you.**
On GitHub a per-repo caller file is structurally unavoidable.

---

## Recommended architecture

For **GitHub-first, single maintainer, 5–20 public repos, low upgrade friction,
GitLab + self-hosted later**:

### What lives where

1. **One public "toolkit" repo** (e.g. `owner/ci-automation`) holds:
   - **A composite action** at `action.yml` (or `/.github/actions/run/`) — half
     (a). It installs pinned `gh`/`glab`/`claude`, sets up the sandbox
     **directly on the runner VM** (bubblewrap or the iptables egress firewall —
     both work on a standard hosted runner with sudo; **not** inside a container
     job, per [[claude-code-sandboxing]] + [[dockerfile-support]]), and runs the
     orchestration scripts. Inputs (`with:`) carry all config; secrets arrive as
     inputs. This is the single source of truth for behavior.
   - **The reference workflow(s)** the loop needs, kept as **copyable templates**
     (this repo is also a **template repository**), because the `on:` triggers
     must live in each consumer.
   - Optionally a **GHCR image** built from this repo pinning the tool versions —
     used now only as a version-pinning base and later as the GitLab/self-hosted
     runtime.

2. **Each consumer repo** holds only thin caller workflow stubs (below).

Why composite action over reusable workflow as the primary carrier: the sandbox
must run on the runner VM (not a container), and the consumer job must own the
`issues: labeled` trigger and `permissions:` block anyway — a composite action
slots into that job and owns the step sequence, while a reusable workflow would
duplicate the job/permission scaffolding the consumer already declares. Reusable
workflows remain a fine choice for any *whole-job* piece you'd rather not have
the consumer see (they can be added later without disrupting the stub).

### How versioning works

- Tag the toolkit repo `v1`, `v1.3.0`, etc. Consumers pin
  `uses: owner/ci-automation/.github/actions/run@v1`.
- Maintain a **floating `v1`** tag (re-pointed on each backward-compatible
  release, the `actions/checkout@v4` pattern) — verified behavior: moving the
  tag repoints all `@v1` consumers on their next run with **zero per-repo
  changes** [[reuse-workflows]]. This is the low-friction lever the constraints
  ask for. Breaking changes cut a `v2` tag; consumers opt in by bumping.
- Security-conscious consumers may pin a **SHA** instead and accept manual
  bumps — "the safest option for stability" [[reusing-workflow-configurations]].
- The GHCR image is versioned by tag **and** immutable digest; pin by digest for
  reproducibility.

### What the consumer repo stub looks like

Structurally unavoidable per-repo file — as thin as it gets. One per trigger the
loop needs (`issues`, `workflow_run`, `pull_request_review`, `schedule`):

```yaml
# .github/workflows/agent-loop.yml   (in EACH consumer repo)
name: agent-loop
on:
  issues:
    types: [labeled]
  pull_request_review:
    types: [submitted]
  workflow_run:
    workflows: [ci]
    types: [completed]
  schedule:
    - cron: "*/30 * * * *"

permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  run:
    runs-on: ubuntu-latest        # standard VM: sudo + bwrap/iptables available
    steps:
      - uses: owner/ci-automation/.github/actions/run@v1   # ← all logic, one pinned line
        with:
          claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          github-app-id: ${{ vars.AGENT_APP_ID }}
          github-app-key: ${{ secrets.AGENT_APP_PRIVATE_KEY }}
```

Everything below `uses:` is owned by the toolkit and upgrades via the floating
tag. The stub only declares triggers, permissions, `runs-on`, and secret wiring
— none of which a reusable workflow or composite action can absorb.
Because `github.event` from the caller flows into the action
[[reuse-workflows]], the action reads the labeled issue / review / upstream run
directly.

### Distributing & updating the stub across repos

- **Seeding:** make the toolkit repo a **template repository**; new consumers
  start from `gh repo create --template`. But a template is a **one-time copy** —
  "a repository created from a template starts with a single commit" and future
  template changes **do not** propagate [[creating-a-repository-from-a-template]].
- **No first-party multi-repo file sync exists.** GitHub has no official
  "sync this stub to N repos" mechanism; template repos don't sync, and
  reusable workflows/composite actions deliberately *don't* cover the trigger
  file. Options: (i) accept that the stub changes rarely (triggers are stable) so
  drift is low; (ii) push stub edits across repos with a small `gh`-scripted
  loop the toolkit itself owns; (iii) third-party file-sync actions exist but are
  **not** first-party — out of scope for a primary-source recommendation, flagged
  **UNVERIFIED** as a supported path.
- The design goal: make the stub so thin (triggers + one `uses@v1`) that it
  almost never needs re-syncing — all churn happens behind the pinned tag.

### Upgrade path to GitLab / self-hosted

1. **Self-hosted (GitHub-compatible):** point a self-hosted runner at the same
   composite action, or run the **GHCR image** via `docker run`. The ADR's
   "direct CLI, not the Action" choice means the in-container command is
   identical to the runner command — portability holds. On self-hosted you
   control privilege, so the iptables/`NET_ADMIN` firewall and bubblewrap work
   without the hosted-runner ambiguity.
2. **GitLab:** re-express half (b) as a **CI/CD component** (GA since 17.0
   [[gitlab-components]]) that runs the **same GHCR image** as `image:` (anon
   pull if public [[working-with-the-container-registry]]). Half (a) — the
   scripts — moves unchanged inside the image. The genuine porting work is
   **triggers**: build a small webhook→`trigger/pipeline`-API bridge for
   `issues`/MR-review events, and use pipeline schedules for the cron leg
   [[gitlab-triggers]]. This is contained because CONTEXT.md already mandates
   that **all loop state lives in the forge's own primitives**, so the GitLab
   port reconstructs the state machine from labels/comments rather than needing
   GitHub-specific event semantics.

### One-line summary of the shape

Logic → **composite action, floating `@v1` tag**. Triggers → **thin per-repo
stub** (unavoidable). Portability → **public GHCR image** as the shared runtime
for GitLab/self-hosted. Sandbox → **on the runner VM, never nested in a
container job** on GitHub.

---

## Sources

<a id="reuse-workflows"></a>**[reuse-workflows]** Reuse workflows —
https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows

<a id="reusing-workflow-configurations"></a>**[reusing-workflow-configurations]**
Reusing workflow configurations (reference) —
https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations

<a id="creating-a-composite-action"></a>**[creating-a-composite-action]**
Creating a composite action —
https://docs.github.com/en/actions/sharing-automations/creating-actions/creating-a-composite-action

<a id="run-jobs-in-a-container"></a>**[run-jobs-in-a-container]** Running jobs in
a container —
https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/run-jobs-in-a-container

<a id="dockerfile-support"></a>**[dockerfile-support]** Dockerfile support for
GitHub Actions —
https://docs.github.com/en/actions/reference/workflows-and-actions/dockerfile-support

<a id="working-with-the-container-registry"></a>**[working-with-the-container-registry]**
Working with the Container registry (GHCR) —
https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry

<a id="creating-a-repository-from-a-template"></a>**[creating-a-repository-from-a-template]**
Creating a repository from a template —
https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template

<a id="claude-code-setup"></a>**[claude-code-setup]** Claude Code — Advanced setup
(install/pin versions) — https://code.claude.com/docs/en/setup

<a id="claude-code-sandboxing"></a>**[claude-code-sandboxing]** Claude Code —
Configure the sandboxed Bash tool (bubblewrap, `enableWeakerNestedSandbox`,
containers, AppArmor userns) — https://code.claude.com/docs/en/sandboxing

<a id="npx"></a>**[npx]** npm CLI — `npx` —
https://docs.npmjs.com/cli/v10/commands/npx

<a id="gitlab-components"></a>**[gitlab-components]** GitLab — CI/CD components —
https://docs.gitlab.com/ci/components/

<a id="gitlab-includes"></a>**[gitlab-includes]** GitLab — `include:` —
https://docs.gitlab.com/ci/yaml/includes/

<a id="gitlab-triggers"></a>**[gitlab-triggers]** GitLab — Trigger pipelines —
https://docs.gitlab.com/ci/triggers/
