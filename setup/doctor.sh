#!/usr/bin/env bash
# doctor.sh — drift check for an onboarded consumer repo (Milestone 4).
#
#   doctor.sh <owner/repo> [--expect-ref v1]
#
# Re-checks everything setup-repo.sh establishes, plus stub version drift.
# Exits NONZERO on any problem, so it can gate a scheduled toolkit-repo audit
# across every onboarded repo. Read-only: never mutates the consumer.
#
# Every ✗/⚠ carries its one-line remedy (M8): an exact command, or an anchor
# into docs/GETTING-STARTED.md. ⚠ is degraded-but-not-failing (exit stays 0).
set -euo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "$_dir/.." && pwd)"
. "$_root/scripts/lib/common.sh"
. "$_root/scripts/lib/config.sh"      # label vocabulary
. "$_root/scripts/lib/onboarding.sh"  # App JWT + install evidence

EXPECT_REF="v1"
FAILED=0
ok()   { printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; FAILED=1; }
warn() { printf '  ⚠ %s\n' "$*"; }
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
      bad ".smallhours.yml invalid, checking canonical labels instead — fix: edit its labels: mapping (schema: bottom of docs/IMPLEMENTATION-PLAN.md)"
      export SMALLHOURS_CONFIG="$tmp.absent"
    fi
  else
    export SMALLHOURS_CONFIG="$tmp.absent"   # config check reports the absence
  fi
}

check_secrets() { # repo
  local present s fix; present="$(gh secret list --repo "$1" --json name --jq '.[].name' 2>/dev/null || gh secret list --repo "$1" | awk '{print $1}')"
  for s in AGENT_APP_ID AGENT_APP_PRIVATE_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    case "$s" in
      CLAUDE_CODE_OAUTH_TOKEN) fix="claude setup-token, then gh secret set $s --repo $1" ;;
      *)                       fix="setup/create-app.sh $1 (sets both App secrets)" ;;
    esac
    printf '%s\n' "$present" | grep -Fxq "$s" && ok "secret $s" || bad "secret $s missing — fix: $fix"
  done
  note "presence only — an empty or expired value still passes (an interrupted 'gh secret set' can store empty); validity is proven by the first agent-loop run"
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
    || bad "missing labels: ${miss[*]} — fix: setup/setup-repo.sh $1 (recreates the vocabulary)"
  # Attempt counters (T3', M6) are created on demand by state.sh, so absence is
  # cosmetic (they'd appear uncolored) — a note, not a failure.
  local i cap missing_attempts=()
  cap="$(config_attempt_cap)"
  i=1
  while [ "$i" -le "$cap" ]; do
    printf '%s\n' "$have" | grep -Fxq "autofix-attempt-$i" || missing_attempts+=("autofix-attempt-$i")
    i=$((i + 1))
  done
  [ "${#missing_attempts[@]}" -eq 0 ] \
    && ok "autofix-attempt-1..$cap labels present" \
    || note "autofix-attempt labels not pre-created (${missing_attempts[*]}) — created on demand; re-run setup for colors"
}

# The triage vocabulary doc in the knowledge layer (Pocock flow, 06-6). Its
# system-owned note is the contract; a hand-deleted or pre-setup repo fails.
check_triage_doc() { # repo default-branch
  local content; content="$(_fetch "$1" "docs/agents/triage-labels.md" "$2")"
  if [ -z "$content" ]; then bad "docs/agents/triage-labels.md missing — fix: setup/setup-repo.sh $1 (imports/generates it)"; return; fi
  printf '%s' "$content" | grep -q '## System-owned states' \
    && ok "triage-labels.md present with system-owned-states note" \
    || bad "triage-labels.md lacks the system-owned-states note — fix: setup/setup-repo.sh $1 (re-appends it)"
}

# ── Fixer App install + permissions (ADR 0006: edge upserts need issues WRITE)
# The dependencies endpoints ride under the "Issues" permission — GitHub has
# no separate issue-dependencies permission (docs: permissions-required-for-
# github-apps, verified 2026-07-24). App permissions are only readable AS the
# App. With AGENT_APP_ID + AGENT_APP_PRIVATE_KEY_FILE set we mint a JWT and
# check for real; without them we fall back to secret-free run evidence (M8):
# a past successful agent-loop run proves token minting, i.e. the App is
# installed with working credentials. A missing permission still fails LOUDLY
# at dispatch time (upsert comments and fails closed).
check_app_install() { # repo
  if [ -z "${AGENT_APP_ID:-}" ] || [ -z "${AGENT_APP_PRIVATE_KEY_FILE:-}" ] || [ ! -f "${AGENT_APP_PRIVATE_KEY_FILE:-/nonexistent}" ]; then
    case "$(ob_app_install_evidence "$1")" in
      proven)
        ok "Fixer App installed (a past agent-loop run succeeded, so App-token minting works)" ;;
      no-runs)
        warn "Fixer App likely NOT installed (no agent-loop runs yet, so token minting is unproven) — fix: setup/create-app.sh $1 (or the App page → Install App)" ;;
      *)
        warn "Fixer App install unproven (agent-loop has run, never successfully) — check https://github.com/$1/actions; if runs die at app-token, fix: setup/create-app.sh $1" ;;
    esac
    note "authoritative check: set AGENT_APP_ID + AGENT_APP_PRIVATE_KEY_FILE (create-app.sh saves the key under ~/.smallhours/) and re-run"
    return
  fi
  local jwt inst slug perms
  jwt="$(ob_app_jwt "$AGENT_APP_ID" "$AGENT_APP_PRIVATE_KEY_FILE")"
  slug="$(curl -fsS -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
            https://api.github.com/app 2>/dev/null | jq -r '.slug // empty')"
  inst="$(ob_app_installation "$1" "$jwt")"
  if [ -z "$inst" ]; then
    bad "Fixer App not installed on $1 (or the JWT was rejected) — fix: https://github.com/apps/${slug:-<your-app-slug>}/installations/new"
    return
  fi
  perms="$(printf '%s' "$inst" | jq -r '.permissions.issues // "none"')"
  [ "$perms" = "write" ] \
    && ok "App installed, permission issues: write (covers issue dependencies — edge upserts OK)" \
    || bad "App permission issues: $perms, need write — fix: https://github.com/settings/apps/${slug:-<your-app-slug>}/permissions"
}

check_stub() { # repo default-branch
  local content resync="setup/setup-repo.sh $1 (re-lands the current stub)"
  content="$(_fetch "$1" ".github/workflows/agent-loop.yml" "$2")"
  [ -n "$content" ] || { bad "stub .github/workflows/agent-loop.yml missing — fix: $resync"; return; }
  # Version drift: the uses: line must pin the expected channel.
  local ref
  ref="$(printf '%s' "$content" | sed -n 's#.*/agent-loop\.yml@\([A-Za-z0-9._-]\{1,\}\).*#\1#p' | head -1)"
  if [ -z "$ref" ]; then bad "stub has no bcanfield/smallhours agent-loop.yml@REF reference — fix: $resync"
  elif [ "$ref" = "$EXPECT_REF" ]; then ok "stub pins @$ref"
  else bad "stub pins @$ref, expected @$EXPECT_REF (version drift) — fix: $resync"; fi
  # Every trigger surface must be present or a route silently never fires.
  # (`pull_request:` never substring-matches `pull_request_review:` — the colon
  # placement differs.)
  local t missing=()
  for t in "issues:" "pull_request:" "pull_request_review:" "workflow_run:" \
           "schedule:" "workflow_dispatch:"; do
    printf '%s' "$content" | grep -q "$t" || missing+=("$t")
  done
  [ "${#missing[@]}" -eq 0 ] && ok "stub declares all trigger surfaces" \
    || bad "stub missing triggers: ${missing[*]} — fix: $resync"
  # M7's re-eval route needs review dismissals forwarded.
  printf '%s' "$content" | grep -q "dismissed" \
    && ok "stub forwards review dismissals (T2 re-eval route)" \
    || bad "stub pull_request_review types lack 'dismissed' (re-eval route never fires) — fix: $resync"
}

check_config() { # repo default-branch
  local content; content="$(_fetch "$1" ".smallhours.yml" "$2")"
  [ -n "$content" ] && ok ".smallhours.yml present" \
    || bad ".smallhours.yml missing — fix: setup/setup-repo.sh $1 (lands the default config)"
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
      bad "$2 is not protected (no PR requirement via ruleset or legacy protection) — fix: setup/setup-repo.sh $1 (sets protection)"
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
      || bad "no required status checks / up-to-date policy — fix: setup/setup-repo.sh $1 --required-checks <check-name>"
  fi
}

check_secret_scanning() { # repo
  local st; st="$(gh api "repos/$1" --jq '.security_and_analysis.secret_scanning_push_protection.status' 2>/dev/null || echo unknown)"
  [ "$st" = "enabled" ] && ok "secret-scanning push protection enabled" \
    || bad "secret-scanning push protection not enabled ($st) — fix: setup/setup-repo.sh $1 (re-enables it; org policy may block)"
}

check_auto_delete() { # repo
  local v; v="$(gh repo view "$1" --json deleteBranchOnMerge --jq .deleteBranchOnMerge 2>/dev/null)"
  [ "$v" = "true" ] && ok "auto-delete head branch on merge enabled (T8 cleanup)" \
    || bad "auto-delete head branch on merge not enabled (merged agent branches will linger) — fix: gh repo edit $1 --delete-branch-on-merge"
}

# Check for the workflow the CONSUMER's config gates on (default 'ci'), not a
# hardcoded name — a repo onboarded with --ci-workflow "Build" must pass. Exact
# match first: workflow_run filters are case-sensitive, so a case-only hit is
# itself drift, with its own remedy.
check_ci() { # repo
  local want names
  want="$(config_ci_workflow)"
  names="$(gh api "repos/$1/actions/workflows" --jq '.workflows[] | select(.state=="active") | .name' 2>/dev/null)"
  if printf '%s\n' "$names" | grep -qxF "$want"; then
    ok "CI workflow '$want' exists (the loop keys off it)"
  elif printf '%s\n' "$names" | grep -qixF "$want"; then
    bad "CI workflow case mismatch: config gates on '$want', repo has '$(printf '%s\n' "$names" | grep -ixF "$want" | head -1)' — workflow_run filters are case-sensitive; fix: re-run setup/setup-repo.sh $1 --ci-workflow with the exact display name"
  else
    bad "no active CI workflow named '$want' — fix: add one (docs/GETTING-STARTED.md#prerequisites) or set ci_workflow in .smallhours.yml to your workflow's exact display name"
  fi
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
  gh repo view "$repo" >/dev/null 2>&1 || sh_die "cannot access $repo (check the name and your gh auth)"
  local def; def="$(gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name)"

  printf 'smallhours doctor — %s (@%s expected, default branch %s)\n' "$repo" "$EXPECT_REF" "$def"
  load_consumer_config "$repo" "$def"
  check_secrets "$repo"
  check_labels "$repo"
  check_stub "$repo" "$def"
  check_config "$repo" "$def"
  check_triage_doc "$repo" "$def"
  check_app_install "$repo"
  check_secret_scanning "$repo"
  check_auto_delete "$repo"
  check_protection "$repo" "$def"
  check_ci "$repo"

  echo
  if [ "$FAILED" -eq 0 ]; then echo "doctor: clean"; else echo "doctor: DRIFT DETECTED"; fi
  exit "$FAILED"
}

main "$@"
