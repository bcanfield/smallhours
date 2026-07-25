#!/usr/bin/env bash
# create-app.sh — create the Fixer GitHub App via the manifest flow (Milestone 8).
#
#   create-app.sh <owner/repo> [--org ORG] [--name NAME] [--port N]
#
# Replaces the manual "register a GitHub App in the UI" prerequisite: opens the
# browser on a pre-filled registration (name, the four Fixer permissions,
# webhook off), catches GitHub's redirect on a localhost listener, exchanges
# the one-time code for the App ID + private key, and sets both repo secrets
# (AGENT_APP_ID, AGENT_APP_PRIVATE_KEY) via `gh secret set`. Ends by verifying
# the App is INSTALLED on the repo — the one step GitHub reserves for a human
# click — and deep-links straight to it when missing.
#
# The manual UI path remains documented in GETTING-STARTED.md as the fallback.
# The third secret (CLAUDE_CODE_OAUTH_TOKEN) is not this script's job; see
# GETTING-STARTED.md#3-set-the-claude-token.
set -euo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "$_dir/.." && pwd)"
. "$_root/scripts/lib/common.sh"
. "$_root/scripts/lib/onboarding.sh"

ORG=""
APP_NAME=""
PORT=8237
KEY_DIR="${SMALLHOURS_KEY_DIR:-$HOME/.smallhours}"

usage() { echo "usage: create-app.sh <owner/repo> [--org ORG] [--name NAME] [--port N]" >&2; }

require_tools() {
  local t
  for t in jq openssl curl nc; do
    command -v "$t" >/dev/null 2>&1 || sh_die "missing tool: $t — install it and re-run"
  done
}

open_url() { # file-or-url
  if command -v open >/dev/null 2>&1; then open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1"
  else sh_log "open this in your browser: $1"; fi
}

# Registration page the browser lands on: an auto-submitting form POSTing the
# manifest. GitHub then shows its own confirm page where the name is editable.
write_form_html() { # out-file manifest-json post-url
  cat > "$1" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>smallhours — register the Fixer App</title>
<body>
<p>Redirecting to GitHub to register the Fixer App…</p>
<form action="$3" method="post">
  <input type="hidden" name="manifest" id="m">
  <noscript><button type="submit">Register the Fixer App</button></noscript>
</form>
<script>
  document.getElementById("m").value = JSON.stringify($2);
  document.forms[0].submit();
</script>
</body>
HTML
}

# One-shot HTTP listener: serve a static "return to the terminal" page to
# whatever connects, capture the request line. BSD nc takes `-l PORT`, GNU
# netcat needs `-l -p PORT` — try in that order. Returns nc's status, not
# head's, so a busy/unbindable port is distinguishable from an empty request.
listen_once() { # port -> request line on stdout
  local resp
  resp="$(printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<!doctype html><meta charset="utf-8"><body><p>✓ Fixer App registered — return to your terminal.</p></body>')"
  { printf '%s' "$resp" | nc -l "$1" 2>/dev/null \
      || printf '%s' "$resp" | nc -l -p "$1"; } | head -1
  return "${PIPESTATUS[0]}"
}

main() {
  local repo=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --org)  ORG="$2"; shift 2 ;;
      --name) APP_NAME="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*)     usage; exit 64 ;;
      *)      [ -z "$repo" ] && repo="$1" || { usage; exit 64; }; shift ;;
    esac
  done
  [ -n "$repo" ] || { usage; exit 64; }

  require_tools
  sh_require_auth
  gh repo view "$repo" >/dev/null 2>&1 || sh_die "cannot access $repo (check the name and your gh auth)"
  # Default name is per-owner: App slugs are globally unique across GitHub, so
  # a bare "smallhours-fixer" would collide. Editable on GitHub's confirm page.
  [ -n "$APP_NAME" ] || APP_NAME="smallhours-fixer-${repo%%/*}"
  # The name lands inside the form page's inline <script>; keep it inert.
  case "$APP_NAME" in
    *[!A-Za-z0-9._\ -]*) sh_die "--name may only contain letters, digits, spaces, . _ -" ;;
  esac

  local redirect manifest form
  redirect="http://127.0.0.1:$PORT/callback"
  manifest="$(ob_manifest_json "$APP_NAME" "https://github.com/$repo" "$redirect")"
  form="$(mktemp "${TMPDIR:-/tmp}/smallhours-app-form.XXXXXX").html"
  write_form_html "$form" "$manifest" "$(ob_manifest_post_url "$ORG")"

  sh_log "opening the pre-filled App registration in your browser"
  sh_log "  (name: $APP_NAME · permissions: contents/issues/PRs write, actions read · webhook: off)"
  open_url "$form"

  # GitHub redirects to localhost with a one-time code (valid 1h). Browsers can
  # open extra connections (favicon); listen until a code actually arrives.
  sh_log "waiting for GitHub to redirect back on port $PORT … (Ctrl-C to abort)"
  local code="" tries=0 reqline
  while [ -z "$code" ] && [ "$tries" -lt 5 ]; do
    reqline="$(listen_once "$PORT")" || sh_die "could not listen on port $PORT — pass --port <free-port> and re-run"
    code="$(ob_code_from_request "$reqline")"
    tries=$((tries + 1))
  done
  [ -n "$code" ] || sh_die "no registration code arrived on port $PORT — re-run and finish the browser flow"

  # Exchange the code for the App's credentials (one-time, unauthenticated).
  local conv id slug pem
  conv="$(curl -fsS -X POST -H "Accept: application/vnd.github+json" \
            "https://api.github.com/app-manifests/$code/conversions")" \
    || sh_die "code exchange failed (codes expire after 1h and are single-use) — re-run"
  id="$(printf '%s' "$conv" | jq -r .id)"
  slug="$(printf '%s' "$conv" | jq -r .slug)"
  pem="$(printf '%s' "$conv" | jq -r .pem)"
  sh_log "✓ App registered: $slug (App ID $id)"

  # Keep a local key copy: GitHub never re-shows it, and doctor.sh uses it for
  # the authoritative install/permission check (AGENT_APP_PRIVATE_KEY_FILE).
  mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
  local key_file="$KEY_DIR/$slug.private-key.pem"
  umask 177
  printf '%s\n' "$pem" > "$key_file"
  umask 022
  sh_log "✓ private key saved to $key_file (chmod 600 — the only copy outside the repo secret)"

  gh secret set AGENT_APP_ID          --repo "$repo" --body "$id"
  gh secret set AGENT_APP_PRIVATE_KEY --repo "$repo" --body "$pem"
  sh_log "✓ secrets AGENT_APP_ID + AGENT_APP_PRIVATE_KEY set on $repo"

  # Installation is the one human click automation can't do (a user token
  # can't install an App). Deep-link it, then confirm as the App.
  local install_url="https://github.com/apps/$slug/installations/new"
  if [ -z "$(ob_app_installation "$repo" "$(ob_app_jwt "$id" "$key_file")")" ]; then
    sh_log "→ one click left: install $slug on $repo"
    sh_log "  $install_url"
    open_url "$install_url"
    printf 'smallhours: press Enter once installed… ' >&2; read -r _
    if [ -n "$(ob_app_installation "$repo" "$(ob_app_jwt "$id" "$key_file")")" ]; then
      sh_log "✓ $slug installed on $repo"
    else
      sh_log "⚠ $slug still not installed on $repo — finish the click at $install_url, then verify with setup/doctor.sh $repo"
    fi
  else
    sh_log "✓ $slug installed on $repo"
  fi

  sh_log "Fixer App done. Next: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token), then run setup/setup-repo.sh $repo"
}

main "$@"
