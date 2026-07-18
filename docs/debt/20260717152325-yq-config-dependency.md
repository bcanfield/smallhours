---
id: 20260717152325
title: yq-config-dependency
principal: 2h
interest: unknown
hotspot: scripts/lib/config.sh
business_capability: infrastructure
payoff_trigger: self-hosted/GitLab milestone finds yq hard to provision, or config grows to need a real schema
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-17
---

Added pinned `yq` to the toolchain to read `.smallhours.yml`, deviating from the DESIGN's "gh + jq only" contract because jq cannot parse YAML's nested config maps. yq's surface is one `yq -o=json` conversion in lib/config.sh; everything else stays jq. Mirrors ADR 0004. Revisit at the self-hosted/GitLab milestone or if config outgrows flat getters.
