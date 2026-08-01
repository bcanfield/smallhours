#!/usr/bin/env bash
# lib/onboarding.sh — helpers shared by the setup/ tools (create-app.sh,
# setup-repo.sh, doctor.sh): the App-manifest payload, the manifest-flow
# callback parser, App JWT minting, and the ending checklist. Source this; do
# not execute. Pure helpers up top (tests/test-onboarding.sh); the two
# network-touching helpers (JWT/installation) are at the bottom.

[ -n "${_SMALLHOURS_ONBOARDING_SH:-}" ] && return 0
_SMALLHOURS_ONBOARDING_SH=1

# ── App manifest (create-app.sh) ─────────────────────────────────────────────
# The Fixer's permission set is the one GETTING-STARTED documents: Contents
# R/W, Issues R/W (also covers issue-dependency upserts, ADR 0006), Pull
# requests R/W, Actions Read. No hook_attributes: the loop is Actions-driven,
# not webhook-driven, and a manifest with a webhook would demand a URL — this
# is the "webhook must be unchecked" tripwire, handled structurally here.
#
# `workflows` is ABSENT on purpose (ADR 0013). GitHub gates any push touching
# `.github/workflows/*` on that permission separately from `contents: write`, so
# such a change cannot land through the loop and is a human class. Adding it here
# would not migrate existing installs either — every one would have to re-consent.
ob_manifest_json() { # name homepage-url redirect-url
  jq -n --arg name "$1" --arg url "$2" --arg redirect "$3" '{
    name: $name,
    url: $url,
    redirect_url: $redirect,
    public: false,
    default_permissions: {
      contents: "write",
      issues: "write",
      pull_requests: "write",
      actions: "read"
    }
  }'
}

# Where the manifest form POSTs: personal account, or an org's app settings.
ob_manifest_post_url() { # [org]
  if [ -n "${1:-}" ]; then printf 'https://github.com/organizations/%s/settings/apps/new' "$1"
  else printf 'https://github.com/settings/apps/new'; fi
}

# Extract the temporary code from the callback's HTTP request line
# ("GET /callback?code=XXX&state=YYY HTTP/1.1"). Empty when absent.
ob_code_from_request() { # request-line
  printf '%s' "$1" | sed -n 's/^[A-Z]* [^ ]*[?&]code=\([A-Za-z0-9_-]*\).*/\1/p'
}

# ── Ending checklist (setup-repo.sh) ─────────────────────────────────────────
# Accumulate met/unmet items during a run; render once at the end (terminal)
# and mirror into the onboarding PR body (markdown). warn = degraded but not
# blocking; only fail counts as unmet.
OB_CHECK_STATUS=() OB_CHECK_ITEM=()

ob_checklist_reset() { OB_CHECK_STATUS=(); OB_CHECK_ITEM=(); }

ob_check() { # ok|warn|fail name remedy-or-detail
  OB_CHECK_STATUS+=("$1"); OB_CHECK_ITEM+=("$2 — $3")
}

ob_checklist_render() {
  local i mark
  for i in "${!OB_CHECK_STATUS[@]}"; do
    case "${OB_CHECK_STATUS[$i]}" in
      ok)   mark='✓' ;;
      warn) mark='⚠' ;;
      *)    mark='✗' ;;
    esac
    printf ' %s %s\n' "$mark" "${OB_CHECK_ITEM[$i]}"
  done
}

ob_checklist_markdown() {
  local i box
  for i in "${!OB_CHECK_STATUS[@]}"; do
    case "${OB_CHECK_STATUS[$i]}" in
      ok) box='[x]' ;;
      *)  box='[ ]' ;;
    esac
    printf -- '- %s %s\n' "$box" "${OB_CHECK_ITEM[$i]}"
  done
}

ob_checklist_unmet() {
  local i n=0
  for i in "${!OB_CHECK_STATUS[@]}"; do
    [ "${OB_CHECK_STATUS[$i]}" = "fail" ] && n=$((n+1))
  done
  printf '%s' "$n"
}

# ── App auth (doctor.sh, create-app.sh) ──────────────────────────────────────
# Mint a short-lived App JWT from the private key. App-level endpoints
# (installation lookup, permission read) accept only this — never a user token.
ob_app_jwt() { # app-id key-file
  local now hdr pld sig
  now="$(date +%s)"
  _ob_b64url() { openssl base64 -A | tr -d '=' | tr '/+' '_-'; }
  hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | _ob_b64url)"
  pld="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$1" | _ob_b64url)"
  sig="$(printf '%s.%s' "$hdr" "$pld" | openssl dgst -sha256 -sign "$2" -binary | _ob_b64url)"
  printf '%s.%s.%s' "$hdr" "$pld" "$sig"
}

# The App's installation on a repo, as the App itself. Prints the installation
# JSON (with .permissions) or nothing when not installed / JWT rejected.
ob_app_installation() { # repo jwt
  curl -fsS -H "Authorization: Bearer $2" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$1/installation" 2>/dev/null || true
}

# Secret-free best-effort install evidence: every agent-loop job's first step
# mints an App installation token, so ONE past successful run proves the App
# is installed with working credentials. Prints: proven | no-runs |
# runs-no-success. Only the App's own JWT can do better (ob_app_installation).
ob_app_install_evidence() { # repo
  local total success
  total="$(gh api "repos/$1/actions/workflows/agent-loop.yml/runs?per_page=1" \
             --jq .total_count 2>/dev/null || echo 0)"
  if [ "${total:-0}" -eq 0 ]; then printf 'no-runs'; return; fi
  success="$(gh api "repos/$1/actions/workflows/agent-loop.yml/runs?status=success&per_page=1" \
               --jq .total_count 2>/dev/null || echo 0)"
  [ "${success:-0}" -ge 1 ] && printf 'proven' || printf 'runs-no-success'
}
