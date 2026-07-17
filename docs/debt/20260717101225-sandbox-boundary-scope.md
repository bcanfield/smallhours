---
id: 20260717101225
title: sandbox-boundary-scope
principal: 1d
interest: unknown until spike 0a runs; if WebFetch leaks, ADR 0001 reopens
hotspot: docs/adr/0001-sandboxed-full-permissions-direct-cli.md
business_capability: agent-runtime-security
payoff_trigger: spike 0a results land -> write ADR 0001 addendum scoping the boundary claim to Bash, and either accept Write/Edit blast radius on the ephemeral runner or adopt @anthropic-ai/sandbox-runtime for whole-process containment
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-17
---

ADR 0001 asserts "sandbox is the boundary" without qualification, but Claude Code's sandbox applies to the Bash tool only — Anthropic's own settings README states it does not apply to Read, Write, WebSearch, WebFetch, MCPs, hooks, or internal commands. So WebFetch/WebSearch egress bypasses sandbox.network.allowedDomains entirely, and Write/Edit bypass sandbox.filesystem.* (ungated under --dangerously-skip-permissions).

The spike's hardened profile mitigates the egress half via permissions.deny of WebFetch/WebSearch plus allowManagedPermissionRulesOnly, but whether a deny rule actually holds under --dangerously-skip-permissions is unverified — that is precisely what spike 0a now tests rather than assumes.

Two settings keys are load-bearing in ways the ADR does not mention: failIfUnavailable (without it a missing bubblewrap downgrades to a warning and Claude runs UNSANDBOXED) and allowManagedDomainsOnly (without it a new domain prompts, and an unattended -p run has nobody to prompt). Registered as deliberate: the plan says an unbuildable spec is a finding for the maintainer, not a licence to redesign, so the posture stays as specified until the spike reports.
