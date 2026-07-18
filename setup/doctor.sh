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

# Fetch a file's decoded contents from the consumer (empty if absent).
_fetch() { gh api "repos/$1/contents/$2?ref=$3" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true; }

check_secrets() { # repo
  local present s; present="$(gh secret list --repo "$1" --json name --jq '.[].name' 2>/dev/null || gh secret list --repo "$1" | awk '{print $1}')"
  for s in AGENT_APP_ID AGENT_APP_PRIVATE_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    printf '%s\n' "$present" | grep -Fxq "$s" && ok "secret $s" || bad "secret $s missing"
  done
}

check_labels() { # repo
  local have name; have="$(gh label list --repo "$1" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  local want=("${SMALLHOURS_STATE_LABELS[@]}" "${SMALLHOURS_PR_LABELS[@]}" "${SMALLHOURS_CATEGORY_LABELS[@]}")
  local miss=()
  for name in "${want[@]}"; do printf '%s\n' "$have" | grep -Fxq "$name" || miss+=("$name"); done
  [ "${#miss[@]}" -eq 0 ] && ok "all ${#want[@]} labels present" || bad "missing labels: ${miss[*]}"
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
  check_secrets "$repo"
  check_labels "$repo"
  check_stub "$repo" "$def"
  check_config "$repo" "$def"
  check_secret_scanning "$repo"
  check_protection "$repo" "$def"
  check_ci "$repo"

  echo
  if [ "$FAILED" -eq 0 ]; then echo "doctor: clean"; else echo "doctor: DRIFT DETECTED"; fi
  exit "$FAILED"
}

main "$@"
