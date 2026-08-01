---
id: 20260731225135
title: bounded-verify-disk-probe
principal: 1h
interest: a completed search over the wrong roots still reports 'not found under', which tells a consumer the gate's failure is theirs to fix when it may be ours
hotspot: scripts/lib/verify.sh
business_capability: verify-gate
payoff_trigger: a consumer disputes a 'not found under' verdict for a tool that is on the runner
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-31
---

ADR 0012 decision 2 has the gate say, on a could-not-run failure, whether the
missing tool exists on the machine at all — the line that decides whether the
failure is the consumer's contract to meet or ours to fix.

That verdict rests on a search bounded three ways: a fixed root list
($HOME/.local, ~/.cache, ~/.npm, ~/.config, /usr/local/bin, /usr/local/lib,
$PWD), -maxdepth 6, and an 8-second ceiling, because a consumer's package store
holds hundreds of thousands of files and the probe runs on a path that has
already failed.

The timeout half of this was registered as a risk and observed immediately: the
gate-environment job's first run showed a depth-6 walk of /usr/local failing to
finish in 8s on a BARE ubuntu-24.04. That is paid down — the roots narrowed to
the two /usr/local subdirectories that can hold an executable, and a cut-off
search now reports INCONCLUSIVE with a verdict that withholds judgement instead
of borrowing the confident one. A test forces that branch with
SH_VERIFY_PROBE_SECONDS=0.

What remains is narrower and quieter: a search that COMPLETES over the fixed root
list can still miss a tool installed somewhere else, and reports "not found
under", which reads as proof of absence. The roots are a guess at where
self-bootstrapping toolchains land, informed by one ecosystem.
