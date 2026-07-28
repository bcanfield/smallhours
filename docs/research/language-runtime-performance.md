# Language / runtime for the orchestration scripts — raw-performance research

Question asked: **if convenience, ecosystem, and maintenance cost are all worth
zero, what is the absolute most efficient thing to write the toolkit's
orchestration logic in, given exactly how it runs inside GitHub Actions?**

Scope: the ~1,500 lines of bash under `scripts/` (+ `setup/`, `spikes/`
harnesses) that run as short-lived jobs on ephemeral `ubuntu-24.04` hosted
runners. Out of scope: the workflow YAML itself (GitHub-mandated) and the
`claude -p` agent runtime (a vendored binary we invoke, not code we write).

Answer up front: **a single statically linked Rust binary (musl, no framework —
tokio + hyper/rustls + serde), talking to the GitHub API directly over one
multiplexed HTTP/2 connection with GraphQL batching, shipped as a prebuilt
SHA-pinned release artifact.** But the honest headline finding is that the
language is the *fourth* largest lever: the measured wall-clock of every job is
dominated by costs no language touches, and the real wins a rewrite unlocks are
*structural* (connection reuse + request parallelism), not compute.

All timings below tagged **[measured]** were taken on this repo's dev container
(Linux 6.18, x86_64 — same ISA class as hosted runners); GitHub-side latencies
are tagged **[typical]** (network-dependent, not lab-reproducible).

---

## 1. Where the wall-clock actually goes

Every `agent-loop.yml` job, regardless of route, pays this fixed prelude:

| Cost | Time | Language-sensitive? |
|---|---|---|
| Runner queue + VM boot | ~10–60 s [typical] | **No** — GitHub infrastructure |
| `actions/create-github-app-token` | ~1–2 s [typical] | No — network + JWT mint |
| `actions/checkout` of the toolkit | ~1–5 s [typical] | Indirectly (see §5) |
| `curl` yq from GitHub releases + install | ~0.5–2 s [typical] | **Yes — eliminated** by a runtime with native YAML |
| Fetch `.smallhours.yml` via `gh api` | 1 RTT | Foldable into the first API call |

Then the route-specific body:

- **Agent routes** (`implement`, `address_review`, `auto_fix`): `claude -p`
  runs for minutes to tens of minutes (`max_turns` 25–50, 40-minute job
  timeouts). This is **95–99 % of wall-clock**. The wrapper language is
  irrelevant to it, to first *and* second order.
- **State-machine routes** (`authorize`, `dispatch`, `ci_state`, `cancel`,
  `implement_guard`): pure API choreography — tens of sequential `gh`
  invocations. This is the only place a language change is even visible.

Conclusion of §1: any language claim must be evaluated against the
state-machine routes only, and even there against a 15–70 s fixed prelude.

## 2. What bash actually costs (measured)

The scripts' overhead decomposes into three distinct taxes:

**(a) Process-spawn tax.** Every `gh`, `jq`, `yq`, `grep`, `sed`, `awk`,
`mktemp` is a fork+exec. Measured floor: 100 × `/bin/true` = 180 ms (1.8 ms
each); 100 × `jq -n '{}'` = 393 ms (~4 ms each) **[measured]**. A dispatch tick
over N queued issues spawns roughly `2 + 5N` processes (list, per-issue jq
extract, per-issue reconcile with its own gh+grep pipeline, per-issue
`blocked_by` fetch, per-issue accumulate). At N=50 that's ~1 s of pure spawn
overhead. Real but small.

**(b) Quadratic re-parse tax.** `dispatch.sh` builds `entries` by re-invoking
`jq` with the whole accumulated array as `--argjson` once per issue — O(N²)
parse/serialize. Replicated at N=200 (the `gh issue list --limit`):
**1.056 s vs 0.005 s single-pass [measured]** — 200×. This is an algorithmic
artifact of "bash strings as data structures", i.e. a cost the *language*
imposes on the design, not just on execution.

**(c) Sequential-RTT tax — the dominant one.** Every `gh` call is a fresh
process, a fresh TCP+TLS handshake, and a fresh sequential API round-trip
(~100–300 ms each [typical]). `dispatch.sh` at N queued issues issues ≥ 2N+2
API calls *in series*; `state_set_issue` alone is 3 serial calls. A 50-issue
queue tick spends **15–30 s in serial network waits** that are almost entirely
parallelizable — GitHub's REST calls here are independent reads, and the writes
are per-issue independent. Bash cannot express connection reuse at all
(`gh` cannot hold a connection across invocations) and expresses concurrency
only via crude backgrounding that the scripts (correctly, for auditability)
don't use.

Tax (c) dwarfs (a) and (b): the language's *I/O model* matters ~10× more than
its compute speed.

## 3. Candidate runtimes, raw numbers

Hello-world cold start, 20-run average **[measured]**, plus what each does to
taxes (a)–(c):

| Runtime | Cold start | Artifact | Kills spawn tax? | Kills RTT tax? | Notes |
|---|---|---|---|---|---|
| Zig 0.14 (static, ReleaseSmall) | 1.1 ms | 5.7 KB | yes | **no native path** — std.http is HTTP/1.1-only, no HTTP/2; TLS client young; practical route is FFI to libcurl/nghttp2 ⇒ C's numbers | Fastest start + smallest binary measured; both leads are worth ~1 ms and ~300 KB per job — ~0.01 % of a runner boot |
| C (dyn. glibc) | 2.1 ms | 16 KB | yes | yes (hand-rolled) | No safe HTTP/2+TLS+JSON stack without vendoring one — same latency floor as Rust once libcurl et al. are linked, so no headroom *gained* |
| **Rust (static musl)** | **2.4 ms** | **350 KB stripped** | **yes — 1 process/job** | **yes — tokio + hyper HTTP/2 multiplex, rustls** | No GC, no runtime; serde JSON ~GB/s-class; LTO+strip |
| Go (static) | 2.6 ms | 1.4 MB stripped | yes | yes — goroutines + net/http HTTP/2 | GC + runtime scheduler: measurable, irrelevant at this data scale |
| Bun/Node (bundled) | 42 ms (node) | 50–90 MB runtime | yes (1 process) | yes (async) | Cold start + footprint pay per job; node preinstalled on runners mitigates fetch |
| Python | 13 ms bare; 100–500 ms with real imports | needs runtime | yes | partially (asyncio) | Slowest compute; import time recurs per job |
| bash + gh/jq/yq (today) | 3 ms | 0 (preinstalled) | no | **no — structurally cannot** | Baseline |

On raw performance the podium is **Rust ≥ C ≥ Go**, and the gaps between them
on *this* workload are noise: the workload is network-bound, and all three
saturate it identically. Rust is the defensible #1 because it matches C's
floor (no GC, no runtime, same syscall count) while actually possessing a
production TLS/HTTP2/JSON stack to *reach* that floor with — with C you either
vendor those (and land at the same numbers) or lose. Go concedes only a GC and
a fatter binary; on measured cold start it ties. If "raw performance, nothing
else" is the criterion, Rust is the answer; Go is the answer to a question
that wasn't asked (fastest to build), and it trails on every raw metric it
differs on, however slightly.

**Zig, examined properly** (Zig 0.14.1 toolchain, measured on this container):
Zig wins both microbenchmarks outright — 1.1 ms cold start vs Rust's 2.4 ms,
5.7 KB binary vs 350 KB — and part of even that gap is a linker artifact (the
Zig binary is fully static; the C/Rust hellos are glibc PIEs paying the
`ld.so` toll a musl-static Rust build also skips). But the crown is decided by
tax (c), the sequential-RTT tax, and there Zig has **no native path to the
winning design**: as of 0.14, `std.http.Client` speaks HTTP/1.1 only (no
HTTP/2 multiplexing), `std.crypto.tls` is a young TLS-1.3-only client,
async/await has been out of the language since 0.11, and RS256 (the App-token
JWT, §5) needs RSA signing the std library doesn't provide. The practical Zig
implementation therefore links libcurl/nghttp2/OpenSSL — at which point the
hot path *is* C and lands on exactly C's row and C's numbers: the floor is
tied, no headroom gained. That is why Zig shares C's verdict line. Its two
genuine leads — ~1.3 ms of start time and ~300 KB of artifact per job — amortize
against a 15 s runner boot to ~0.01 %, i.e. below measurement noise on any
route. Strictly on raw performance Zig ties Rust at the ceiling; it cannot
raise it, and it reaches it only by becoming C.

Framework: **none.** An orchestration CLI of this size wants tokio + hyper
(or reqwest-on-hyper) + serde + a YAML crate + `jsonwebtoken` (see §5) and
nothing else. Any "framework" is pure overhead here.

## 4. What the Rust binary changes per route (projected)

`dispatch` tick, 50 queued issues, 3 with edges:

| | today (bash) | Rust binary |
|---|---|---|
| Processes spawned | ~250 | 1 |
| TLS handshakes | ~110 | 1 |
| API round-trips | ~110, serial | ~4–6: one GraphQL query for the queue+labels+bodies, batched dependency reads, parallel writes |
| Script wall-clock | ~20–35 s | **~1–2 s** |

`ci_state`, `authorize`, `cancel`, `implement_guard`: 3–8 serial calls each
today → 1–2 batched round-trips; ~2–5 s → **<1 s**.

Cycle detection / promotable computation: the jq fixpoint DFS becomes an
in-process graph pass — microseconds either way at N≤200; not a real cost now,
zero after.

**End-to-end honesty:** those wins sit behind the fixed prelude of §1. Event →
state-transition latency improves from ~40–70 s to ~20–35 s (≈2×, all of it
from script time); the agent routes improve by <1 %. No language moves the
runner boot, the token mint, or `claude -p`.

## 5. Second-order wins the binary unlocks (still raw performance)

- **Replace the yq download** (per-job release fetch) with nothing — YAML is
  parsed in-process. One fewer network fetch per job on every route.
- **Replace the toolkit checkout** on script-only routes with a single ~1 MB
  SHA-pinned binary download (or keep the checkout — the binary can live in
  the repo; `actions/checkout` of this repo is already ~1 s).
- **Mint the App token in-process** (`jsonwebtoken` + one API call) and drop
  the `actions/create-github-app-token` marketplace action — saves an
  action-container spin-up per job (~1–2 s [typical]).
- **Fold config fetch into the first GraphQL query** — also erases the
  duplicated config-fetch step already registered in
  `docs/debt/20260724221825-config-fetch-step-duplicated.md`.

## 6. The finding that outranks the language

For the state-machine routes, the largest cost the system controls is **booting
a VM to run 2 seconds of logic**. The raw-performance endpoint is not a faster
language on Actions — it is *not being on Actions* for those routes: a
webhook-driven receiver (the same Rust binary behind a tiny HTTP listener, or
an edge worker) reacts to `issues`/`workflow_run` events in **<100 ms instead
of 15–60 s** — a 100–500× latency reduction that no on-runner language can
approach. Actions must remain the substrate for the agent routes (the
bubblewrap sandbox needs the runner VM — see
`docs/research/packaging-distribution.md`), and a webhook service reopens
hosting/secrets questions that ADR 0001/0002 deliberately avoided. Recorded
here as the true performance ceiling, **not** proposed; per CLAUDE.md this is
a finding for the maintainer, since it re-litigates the "everything runs in
GitHub Actions" scope decision.

## 7. Costs of the Rust rewrite, stated plainly

Convenience was ruled out of the decision, but two non-convenience facts still
belong on the record:

- The portability contract (ADR 0004 / `lib/config.sh`: "only bash, gh, jq,
  yq") and the GitLab/self-hosted story actually *improve*: one static binary
  is more portable than four tool installs.
- What is genuinely lost is *auditability of the security boundary*: today a
  consumer can read every API call the toolkit makes in plain shell. A binary
  re-introduces a trust step (reproducible builds + SHA pinning mitigate;
  the floating-`v1` model already asks for equivalent trust).

## 8. Verdict

| Rank | Option | Why |
|---|---|---|
| 1 | **Rust, no framework, static musl binary, tokio/hyper/rustls/serde, GraphQL-batched, SHA-pinned prebuilt artifact** | Ties the C floor (3 ms start, 350 KB, zero GC) while actually reaching it; kills all three measured taxes; erases the yq install and token-mint action |
| 2 | Go, same architecture | Indistinguishable in practice (2 ms start measured); loses only on GC/binary-size technicalities — the raw-metrics runner-up |
| 3 | C / Zig | Zig measurably wins cold start (1.1 ms) and binary size (5.7 KB) — worth ~0.01 % of a job; no native HTTP/2/async/RSA path, so both must vendor or FFI a C stack to tie Rust's floor, gaining nothing above the sockets |
| — | Node/Bun, Python | Strictly dominated on every raw metric |
| — | bash (status quo) | Structurally cannot fix the sequential-RTT tax, which is 80 %+ of controllable script time |

And the proportionality caveat that must ride with the verdict: the rewrite
buys ~2× on state-transition latency and ~0 % on agent routes, because runner
boot and `claude -p` own the clock. If raw performance ever becomes the actual
goal, §6 (webhook receiver for the state machine) is worth 100× more than any
language choice — and it would want the same Rust binary.

## 9. Quantified savings (the §8 rewrite, numbers end to end)

Assumptions: hosted-runner boot median ~15 s [typical]; stub cron `*/15`
(96 dispatcher ticks/day per consumer repo); GitHub-side RTT 150–300 ms
[typical]; per-job step costs from §1; script-tax numbers from §2/§4.

**Per-job body** (everything after the runner is up, `claude -p` excluded):

| Route | today | Rust binary | saved |
|---|---|---|---|
| `dispatch` tick, empty queue (the common case, ×96/day) | ~6 s | ~1 s | ~5 s |
| `dispatch`, 5 queued | ~11 s | ~1.5 s | ~9 s |
| `dispatch`, 50 queued | ~25–40 s | ~2 s | ~23–38 s |
| `authorize` | ~7 s | ~1 s | ~6 s |
| `ci_state` (+ state-manager transition) | ~8.5 s | ~1.2 s | ~7 s |
| `cancel` | ~8 s | ~1.2 s | ~7 s |
| `implement_guard` | ~1.5 s | ~0.5 s | ~1 s |
| agent-route prelude (implement / address-review / auto-fix) | ~6 s removable | ~1.5 s | ~4.5 s |

The removals per job: yq release download (~1.5 s), toolkit checkout on
script-only routes (~2 s), `create-github-app-token` action (~1.5 s, minted
in-process instead), config fetch folded into the first GraphQL call
(~0.3 s), and the serial-RTT script body collapsed per §4.

**Event-to-action latency** (runner boots included — they don't move):

| Chain | today | after | delta |
|---|---|---|---|
| label `ready-for-agent` → agent starts implementing (authorize → dispatch → guard → implement, 4 boots) | ~85–110 s | ~60–70 s | **−25–45 s (~30–40 %)** |
| CI red → auto-fix begins (ci_state → auto_fix, 2 boots) | ~45 s | ~33 s | −12 s (~25 %) |
| issue → merged PR, full cycle | `claude -p` + CI dominate | −40–60 s total | **~1–5 %** |

**Daily aggregate, per consumer repo** (96 ticks, ~5 issues worked, ~15 CI
completions): ~12–18 min of runner wall-time saved/day; at the 20-repo target,
~4–6 machine-hours/day. Caveat for *billing*: public repos are free, and
private-repo Actions bill per job **rounded up to the minute**, so a 21 s tick
and a 16 s tick cost the same minute — the money saved is ≈ 0 for public and
marginal for private (only jobs that cross a minute boundary, e.g. the
50-issue dispatch at 2 min → 1 min). The savings are latency and capacity,
not invoice.

**Non-time efficiency gains:**

- **API budget, ~5–10×.** A 5-issue tick today is ~30 REST calls; after, ~3
  (token + one GraphQL query + writes). Per repo/day: low thousands → low
  hundreds. Also retires the secondary-rate-limit risk of rapid serial writes
  — the current failure mode where a throttled tick silently defers promotion
  to the next cron slot (up to 15 min of added latency).
- **A whole failure class deleted.** 96+ yq fetches from
  `github.com/mikefarah/yq/releases` per repo/day is a per-job external
  dependency; any flake fails the job and costs a full cron interval. The
  binary has zero per-job downloads beyond itself (and can be committed,
  making it zero).
- **Supply-chain surface.** Drops the third-party token-mint action, yq, and
  jq from the runtime path; one SHA-pinned artifact remains (§7's
  auditability trade noted).
- **Retry/backoff for free.** One process can retry an individual API call in
  milliseconds; today a failed `gh` mid-script generally fails the job.

Bottom line of the quantification: **5–20× on the job bodies, ~30–40 % on
event-to-action latency, ~1–5 % on issue→merged-PR, ~0 on cost** — and the
per-§6 webhook receiver remains the only move that changes the first number
that users actually feel (the 15–60 s boot in front of every 2-second
decision).
