---
id: 20260725154454
title: create-app-nc-listener-portability
principal: 2h
interest: a failed onboarding on platforms with traditional netcat; die only at listen time
hotspot: setup/create-app.sh
business_capability: infrastructure
payoff_trigger: first onboarding report of the listener failing on a platform
quadrant: prudent-deliberate
category: infrastructure
ai_authored: true
created: 2026-07-25
---

create-app.sh's manifest-flow callback listener depends on nc and guesses the flag dialect (BSD `nc -l PORT` vs GNU `nc -l -p PORT`) by try-then-fallback; traditional/other netcat variants, or an already-occupied port, surface only as a die at listen time with a --port remedy. A small embedded HTTP helper (or a python3 fallback) was deferred to avoid adding a language runtime (python/node) to the setup-tool dependency surface (gh/jq/openssl/curl/nc). The manual UI path in GETTING-STARTED remains the documented workaround.
