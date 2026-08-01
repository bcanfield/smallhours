---
id: 20260731225135
title: bounded-verify-disk-probe
principal: 2h
interest: a false 'never existed' verdict tells a consumer the gate's failure is theirs to fix when it may be ours, and hides an ADR 0012 payoff trigger
hotspot: scripts/lib/verify.sh
business_capability: verify-gate
payoff_trigger: a consumer disputes a 'nothing on this runner provides it' verdict, or the bounded search is observed timing out on a real runner
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-31
---

ADR 0012 decision 2 has the gate say, on a could-not-run failure, whether the
missing tool exists on the machine at all — the line that decides whether the
failure is the consumer's contract to meet or ours to fix.

That verdict rests on a deliberately bounded search: a fixed root list
($HOME/.local, ~/.cache, ~/.npm, ~/.config, /usr/local, $PWD), -maxdepth 6, and
an 8-second watchdog, because one of those roots is normally a package store
holding hundreds of thousands of files and the probe runs on a path that has
already failed. A tool installed outside those roots, nested deeper, or present
on a machine where the walk times out is reported as "nothing on this runner
provides it" — stating absence when the honest answer is "not found within the
budget". The log says the search was bounded; the verdict line does not.

The cost of being wrong is asymmetric in the quiet direction: a false "never
existed" reads as the expected case and closes the question, while the true
finding it hides is exactly ADR 0012's payoff trigger.
