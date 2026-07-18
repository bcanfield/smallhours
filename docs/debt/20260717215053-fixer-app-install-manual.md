---
id: 20260717215053
title: fixer-app-install-manual
principal: 3h
interest: onboarding isn't truly one-command; a missed install fails silently at first run
hotspot: setup/setup-repo.sh
business_capability: infrastructure
payoff_trigger: onboarding a second/third consumer repo, or Milestone 5 if a run fails on a missing install
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-17
---

The plan says setup-repo.sh should "install the Fixer App on the repo," but installing a GitHub App on a repo can't be done reliably with a user token (it needs the App's own JWT or a UI click). setup-repo.sh instead verifies the three secrets and prints a reminder to install via the UI. So onboarding is "one command + one manual App install." A missed install surfaces only when actions/create-github-app-token fails at first trigger. Could be automated later by minting an App JWT from the private key and calling the installation API.
