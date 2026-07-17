# 0004 — pinned `yq` reads `.smallhours.yml`; scripts stay otherwise gh+jq

**Date:** 2026-07-17
**Status:** Accepted

## Context

Milestone 2's portable scripts are specified as "bash, `gh` + `jq` only,
repo-agnostic, config from `.smallhours.yml`" (DESIGN.md packaging; plan M2).
Those two clauses collide: `.smallhours.yml` is YAML with nested maps
(`models.implement`, `max_turns.address_review`), and `jq` cannot parse YAML.
Something has to turn the config into something `jq` can read.

## Decision

Add `yq` (mikefarah, single static Go binary) to `versions.env`, pinned like
`gh`/`jq`/`claude`. `lib/config.sh` runs `yq -o=json` **once** to convert the
consumer's `.smallhours.yml` to JSON, then every getter reads that JSON with
`jq`. `yq`'s surface is exactly one line; all real logic stays `jq`. The rest of
the script set touches no YAML and remains gh+jq only.

## Consequences

- One new pinned tool. It installs the same way everywhere (a binary download),
  so it does not weaken the self-hosted/GitLab portability contract — arguably
  strengthens it versus assuming an ambient interpreter.
- The human-friendly `.smallhours.yml` the design chose is preserved; consumers
  never see JSON.
- `versions.env` remains the single source of runtime truth and the future
  Dockerfile input (ADR 0002) — `yq` slots into that pattern.

## Alternatives

- **Ambient `ruby -ryaml -rjson`** — zero install on GitHub/macOS, but Ruby is
  not guaranteed on a GitLab or self-hosted runner; trades a pinned dependency
  for an unpinned assumption. Rejected.
- **Hand-rolled bash/grep YAML parser** — no new dependency, but fragile on
  nested maps and quoting; a config-parsing bug fails closed in confusing ways.
  Rejected.
- **Switch config to `.smallhours.json`** — jq-native, no new tool, but discards
  the human-authored YAML the design and onboarding (`setup-repo.sh`) assume,
  and JSON has no comments for a hand-edited config. Rejected.

## Payoff trigger

Revisit if the self-hosted/GitLab milestone finds `yq` hard to provision, or if
config grows complex enough to want a real schema (JSON Schema on a converted
doc), at which point standardising on JSON internally may win.
