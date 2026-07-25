#!/usr/bin/env bash
# doctor.sh — drift check for an onboarded consumer repo (Milestone 4).
#
#   doctor.sh <owner/repo> [--expect-ref v1]
#
# Re-checks everything setup-repo.sh establishes, plus stub version drift.
# Exits NONZERO on any problem, so it can gate a scheduled toolkit-repo audit
# across every onboarded repo. Read-only: never mutates the consumer.
set -euo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "$_dir/.." && pwd)"
. "$_root/scripts/lib/common.sh"
. "$_root/scripts/lib/config.sh"   # label vocabulary

EXPECT_REF="v1"
FAILED=0
ok()   { printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; FAILED=1; }
note() { printf '  … %s\n' "$*"; }

# Fetch a file's decoded contents from the consumer (empty if absent).
_fetch() { gh api "repos/$1/contents/$2?ref=$3" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true; }

# Point label resolution at the CONSUMER's config so mapped labels are checked
# under their repo strings (06-1/06-6). An invalid mapping is itself drift.
load_consumer_config() { # repo default-branch
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/smallhours-doctor-cfg.XXXXXX")"
  _fetch "$1" ".smallhours.yml" "$2" > "$tmp"
  if [ -s "$tmp" ]; then
    export SMALLHOURS_CONFIG="$tmp"
    if config_load; then
      ok ".smallhours.yml parses (labels mapping valid)"
    else
      bad ".smallhours.yml invalid (labels mapping?) — checking canonical labels instead"
      export SMALLHOURS_CONFIG="$tmp.absent"
    fi
  else
    export SMALLHOURS_CONFIG="$tmp.absent"   # config check reports the absence
  fi
}

check_secrets() { # repo
  local present s; present="$(gh secret list --repo "$1" --json name --jq '.[].name' 2>/dev/null || gh secret list --repo "$1" | awk '{print $1}')"
  for s in AGENT_APP_ID AGENT_APP_PRIVATE_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    printf '%s\n' "$present" | grep -Fxq "$s" && ok "secret $s" || bad "secret $s missing"
  done
}

check_labels() { # repo
  local have name rname; have="$(gh label list --repo "$1" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  local want=("${SMALLHOURS_STATE_LABELS[@]}" "${SMALLHOURS_PR_LABELS[@]}" "${SMALLHOURS_CATEGORY_LABELS[@]}")
  local miss=()
  for name in "${want[@]}"; do
    rname="$(label_for "$name")"
    printf '%s\n' "$have" | grep -Fxq "$rname" || miss+=("$rname")
  done
  [ "${#miss[@]}" -eq 0 ] && ok "all ${#want[@]} labels present (mapping-resolved)" \
    || bad "missing labels (mapping drift): ${miss[*]}"
}

# The triage vocabulary doc in the knowledge layer (Pocock flow, 06-6). Its
# system-owned note is the contract; a hand-deleted or pre-setup repo fails.
check_triage_doc() { # repo default-branch
  local content; content="$(_fetch "$1" "docs/agents/triage-labels.md" "$2")"
  if [ -z "$content" ]; then bad "docs/agents/triage-labels.md missing (setup imports it)"; return; fi
  printf '%s' "$content" | grep -q '## System-owned states' \
    && ok "triage-labels.md present with system-owned-states note" \
    || bad "triage-labels.md lacks the system-owned-states note (drift — re-run setup)"
}

# ── Fixer App permissions (ADR 0006: edge upserts need issue-dependencies) ───
# App permissions are only readable AS the App. With AGENT_APP_ID +
# AGENT_APP_PRIVATE_KEY_FILE set we mint a JWT and check for real; otherwise
# this is a note, not a pass — a missing permission still fails LOUDLY at
# dispatch time (upsert comments and fails closed), so nothing is silent.
_app_jwt() { # app-id key-file
  local now hdr pld sig
  now="$(date +%s)"
  _b64url() { openssl base64 -A | tr -d '=' | tr '/+' '_-'; }
  hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | _b64url)"
  pld="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$1" | _b64url)"
  sig="$(printf '%s.%s' "$hdr" "$pld" | openssl dgst -sha256 -sign "$2" -binary | _b64url)"
  printf '%s.%s.%s' "$hdr" "$pld" "$sig"
}

check_app_permissions() { # repo
  if [ -z "${AGENT_APP_ID:-}" ] || [ -z "${AGENT_APP_PRIVATE_KEY_FILE:-}" ] || [ ! -f "${AGENT_APP_PRIVATE_KEY_FILE:-/nonexistent}" ]; then
    note "Fixer App permissions not verifiable with a user token — set AGENT_APP_ID + AGENT_APP_PRIVATE_KEY_FILE to check. Needed: issues write + issue-dependencies write (edge upserts fail closed and comment if missing)"
    return
  fi
  local jwt perms
  jwt="$(_app_jwt "$AGENT_APP_ID" "$AGENT_APP_PRIVATE_KEY_FILE")"
  perms="$(curl -fsS -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
             "https://api.github.com/repos/$1/installation" 2>/dev/null | jq '.permissions // empty')"
  if [ -z "$perms" ]; then
    bad "Fixer App does not appear to be installed on $1 (or the JWT was rejected)"
    return
  fi
  local issues deps
  issues="$(printf '%s' "$perms" | jq -r '.issues // "none"')"
  [ "$issues" = "write" ] && ok "App permission issues: write" || bad "App permission issues: $issues (need write)"
  deps="$(printf '%s' "$perms" | jq -r 'to_entries[] | select(.key | test("dependenc")) | "\(.key)=\(.value)"')"
  if [ -n "$deps" ]; then
    printf '%s\n' "$deps" | grep -q '=write$' \
      && ok "App permission $deps" \
      || bad "App permission $deps (need write — edge upserts will fail closed)"
  else
    note "no dependencies-specific permission key reported; full map: $(printf '%s' "$perms" | jq -c .)"
  fi
}

check_stub() { # repo default-branch
  local content; content="$(_fetch "$1" ".github/workflows/agent-loop.yml" "$2")"
  [ -n "$content" ] || { bad "stub .github/workflows/agent-loop.yml missing"; return; }
  # Version drift: the uses: line must pin the expected channel.
  local ref
  ref="$(printf '%s' "$content" | sed -n 's#.*/agent-loop\.yml@\([A-Za-z0-9._-]\{1,\}\).*#\1#p' | head -1)"
  if [ -z "$ref" ]; then bad "stub has no bcanfield/smallhours agent-loop.yml@REF reference"
  elif [ "$ref" = "$EXPECT_REF" ]; then ok "stub pins @$ref"
  else bad "stub pins @$ref, expected @$EXPECT_REF (version drift)"; fi
  # The four trigger surfaces must be present or a route silently never fires.
  local t missing=()
  for t in "issues:" "pull_request_review:" "workflow_run:" "schedule:"; do
    printf '%s' "$content" | grep -q "$t" || missing+=("$t")
  done
  [ "${#missing[@]}" -eq 0 ] && ok "stub declares all trigger surfaces" || bad "stub missing triggers: ${missing[*]}"
}

check_config() { # repo default-branch
  local content; content="$(_fetch "$1" ".smallhours.yml" "$2")"
  [ -n "$content" ] && ok ".smallhours.yml present" || bad ".smallhours.yml missing"
}

# Ruleset-aware: modern repos protect via rulesets, which the legacy
# /branches/*/protection endpoint 404s on. Check effective rules first, fall
# back to legacy. "PR required" is the pass condition (it keeps the agent from
# pushing to the default branch and forces a human merge); the design's
# 1-approval target is surfaced as a note, not a hard failure.
check_protection() { # repo default-branch
  local rules; rules="$(gh api "repos/$1/rules/branches/$2" 2>/dev/null || echo '[]')"
  local pr_ruleset approvals rsc strict legacy

  pr_ruleset="$(printf '%s' "$rules" | jq '[.[] | select(.type=="pull_request")] | length')"
  if [ "$pr_ruleset" -ge 1 ]; then
    approvals="$(printf '%s' "$rules" | jq -r 'map(select(.type=="pull_request"))[0].parameters.required_approving_review_count // 0')"
    if [ "$approvals" -ge 1 ]; then ok "PR required, $approvals approval(s) (ruleset)"
    else ok "PR required (ruleset) — note: 0 approvals required; design suggests ≥1"; fi
  else
    legacy="$(gh api "repos/$1/branches/$2/protection" 2>/dev/null || true)"
    if [ -n "$legacy" ]; then
      approvals="$(printf '%s' "$legacy" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')"
      [ "$approvals" -ge 1 ] && ok "PR required, $approvals approval(s) (legacy)" \
        || ok "PR required (legacy) — note: 0 approvals required; design suggests ≥1"
    else
      bad "$2 is not protected (no PR requirement via ruleset or legacy protection)"
    fi
  fi

  rsc="$(printf '%s' "$rules" | jq '[.[] | select(.type=="required_status_checks")] | length')"
  if [ "$rsc" -ge 1 ]; then
    strict="$(printf '%s' "$rules" | jq -r 'map(select(.type=="required_status_checks"))[0].parameters.strict_required_status_checks_policy // false')"
    [ "$strict" = "true" ] && ok "required status checks + up-to-date (ruleset)" \
      || ok "required status checks (ruleset) — note: not strict/up-to-date"
  else
    strict="$(gh api "repos/$1/branches/$2/protection" --jq '.required_status_checks.strict // false' 2>/dev/null || echo false)"
    [ "$strict" = "true" ] && ok "required status checks + up-to-date (legacy)" \
      || bad "no required status checks / up-to-date policy"
  fi
}

check_secret_scanning() { # repo
  local st; st="$(gh api "repos/$1" --jq '.security_and_analysis.secret_scanning_push_protection.status' 2>/dev/null || echo unknown)"
  [ "$st" = "enabled" ] && ok "secret-scanning push protection enabled" || bad "secret-scanning push protection not enabled ($st)"
}

check_auto_delete() { # repo
  local v; v="$(gh repo view "$1" --json deleteBranchOnMerge --jq .deleteBranchOnMerge 2>/dev/null)"
  [ "$v" = "true" ] && ok "auto-delete head branch on merge enabled (T8 cleanup)" \
    || bad "auto-delete head branch on merge not enabled — merged agent branches will linger"
}

check_ci() { # repo
  gh api "repos/$1/actions/workflows" --jq '.workflows[] | select(.state=="active") | .name' 2>/dev/null | grep -qiE '^ci$' \
    && ok "a CI workflow exists (the loop keys off it)" || bad "no active CI workflow found"
}

usage() { echo "usage: doctor.sh <owner/repo> [--expect-ref v1]" >&2; }

main() {
  local repo=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect-ref) EXPECT_REF="$2"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      -*)           usage; exit 64 ;;
      *)            [ -z "$repo" ] && repo="$1" || { usage; exit 64; }; shift ;;
    esac
  done
  [ -n "$repo" ] || { usage; exit 64; }
  sh_require_auth
  gh repo view "$repo" >/dev/null 2>&1 || sh_die "cannot access $repo"
  local def; def="$(gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name)"

  printf 'smallhours doctor — %s (@%s expected, default branch %s)\n' "$repo" "$EXPECT_REF" "$def"
  load_consumer_config "$repo" "$def"
  check_secrets "$repo"
  check_labels "$repo"
  check_stub "$repo" "$def"
  check_config "$repo" "$def"
  check_triage_doc "$repo" "$def"
  check_app_permissions "$repo"
  check_secret_scanning "$repo"
  check_auto_delete "$repo"
  check_protection "$repo" "$def"
  check_ci "$repo"

  echo
  if [ "$FAILED" -eq 0 ]; then echo "doctor: clean"; else echo "doctor: DRIFT DETECTED"; fi
  exit "$FAILED"
}

main "$@"
