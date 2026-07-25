#!/usr/bin/env bash
# setup-repo.sh — one-command consumer onboarding (Milestone 4).
#
#   setup-repo.sh <owner/repo> [--ci-workflow NAME] [--required-checks a,b]
#                              [--skip-protection] [--dry-run]
#
# Idempotent. Brings a repo up to the smallhours consumer contract:
#   1. verify prerequisites (the Fixer App's three secrets)
#   2. detect the CI workflow the loop gates on (name must match exactly —
#      workflow_run filters are case-sensitive)
#   3. create the label vocabulary (state axis + PR markers + category)
#   4. land the stub workflow + default .smallhours.yml, wired to the CI name.
#      If the default branch requires PRs (ruleset or legacy protection), the
#      files land via an onboarding PR rather than a rejected direct push.
#   5. enable secret-scanning push protection
#   6. branch protection: set legacy protection ONLY if the branch isn't already
#      protected — never clobber an existing ruleset.
#
# Run from a clone of the toolkit (reads stub/ templates next to this script).
# Uses your own gh auth (needs `repo` + `workflow` scopes). The Fixer App itself
# must be INSTALLED on the repo via the GitHub UI — that can't be done reliably
# with a user token; this script verifies its secrets and reminds you.
set -euo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "$_dir/.." && pwd)"
. "$_root/scripts/lib/common.sh"
. "$_root/scripts/lib/config.sh"      # label vocabulary
. "$_root/scripts/lib/onboarding.sh"  # ending checklist + App install evidence

DRY_RUN=0
CI_WORKFLOW=""
REQUIRED_CHECKS=""
SKIP_PROTECTION=0
ONBOARD_BRANCH="smallhours-onboarding"
ONBOARD_PR=""   # open onboarding PR number, when landing had to go via PR

# ── label vocabulary: name<TAB>color<TAB>description ───────────────────────────
_labels() {
  cat <<'TSV'
needs-triage	ededed	State: awaiting triage/grilling
needs-info	fbca04	State: blocked on missing information
ready-for-agent	0e8a16	State: grilled + authorized; the loop's trigger
agent-working	1d76db	State: smallhours is implementing/fixing/resolving
in-review	5319e7	State: PR ready; maintainer review is the only pending act
ready-for-human	d93f0b	State: needs a person, not the agent
wontfix	ffffff	State: will not be worked
agent	bfd4f2	PR: automation-owned; smallhours may modify
ci-failing	b60205	PR: CI red
ready-to-merge	0e8a16	PR: green + CLEAN, ready for review/merge
human-needed	d93f0b	PR: automation gave up
bug	d73a4a	Category: something is broken
enhancement	a2eeef	Category: new capability or improvement
TSV
}

preflight() { # repo
  local repo="$1"
  sh_require_auth
  gh repo view "$repo" >/dev/null 2>&1 || sh_die "cannot access $repo (check the name and your gh auth)"
  DEFAULT_BRANCH="$(gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name)"
  sh_log "repo $repo, default branch $DEFAULT_BRANCH"
}

# Resolve labels against the CONSUMER's config: a re-run on a repo with a
# custom labels: mapping must create/check the mapped strings, not the
# canonical ones. No config on the repo yet -> canonical defaults.
load_consumer_config() { # repo
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/smallhours-consumer-cfg.XXXXXX")"
  if gh api "repos/$1/contents/.smallhours.yml?ref=$DEFAULT_BRANCH" --jq '.content' 2>/dev/null \
       | base64 -d > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    export SMALLHOURS_CONFIG="$tmp"
    config_load || sh_die "existing .smallhours.yml on $1 is invalid (labels mapping?) — fix it, then re-run"
    sh_log "label resolution uses the repo's existing .smallhours.yml"
  else
    export SMALLHOURS_CONFIG="$tmp.absent"   # no file -> canonical defaults
  fi
}

verify_secrets() { # repo
  local repo="$1" missing=() s present
  present="$(gh secret list --repo "$repo" --json name --jq '.[].name' 2>/dev/null || gh secret list --repo "$repo" | awk '{print $1}')"
  for s in AGENT_APP_ID AGENT_APP_PRIVATE_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    printf '%s\n' "$present" | grep -Fxq "$s" || missing+=("$s")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    local remedy="missing ${missing[*]} — fix: setup/create-app.sh $repo (App secrets) / claude setup-token → gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $repo"
    sh_log "⚠ secrets: $remedy"
    ob_check fail "secrets" "$remedy"
  else
    sh_log "✓ all three Fixer secrets present"
    ob_check ok "secrets" "AGENT_APP_ID, AGENT_APP_PRIVATE_KEY, CLAUDE_CODE_OAUTH_TOKEN present"
  fi
  # Install is the one step only a UI click can do; run evidence is the best a
  # user token gets (doctor.sh with the key file is the authoritative check).
  if [ "$(ob_app_install_evidence "$repo")" = "proven" ]; then
    ob_check ok "Fixer App install" "proven by a past successful agent-loop run"
  else
    ob_check warn "Fixer App install" "unproven (no successful agent-loop run yet) — install: setup/create-app.sh $repo, or the App page → Install App"
  fi
  sh_log "  reminder: the App needs issues WRITE — that permission also covers the native issue-dependency upserts (ADR 0006; no separate dependencies permission exists)"
}

detect_ci_workflow() { # repo
  local repo="$1"
  if [ -n "$CI_WORKFLOW" ]; then sh_log "CI workflow (given): $CI_WORKFLOW"
  else
    local hit
    hit="$(gh api "repos/$repo/actions/workflows" \
            --jq '.workflows[] | select(.state=="active") | .name' \
          | grep -iE '^ci$' | head -1 || true)"
    [ -n "$hit" ] || sh_die "could not auto-detect a CI workflow named 'ci' — fix: re-run with --ci-workflow \"<name>\" (the workflow's display name, exactly), or add CI first (docs/GETTING-STARTED.md#prerequisites)"
    CI_WORKFLOW="$hit"
    sh_log "CI workflow (detected): $CI_WORKFLOW"
  fi
  ob_check ok "CI gate" "loop keys off workflow '$CI_WORKFLOW'"
}

create_labels() { # repo
  local repo="$1" name color desc rname
  while IFS=$'\t' read -r name color desc; do
    [ -n "$name" ] || continue
    rname="$(label_for "$name")"   # the consumer's string for the canonical name
    if [ "$DRY_RUN" -eq 1 ]; then printf 'DRY-RUN: label %s\n' "$rname" >&2; continue; fi
    gh label create "$rname" --repo "$repo" --color "$color" --description "$desc" 2>/dev/null \
      || gh label edit "$rname" --repo "$repo" --color "$color" --description "$desc" >/dev/null
  done < <(_labels)
  # Auto-fix attempt counters (T3', M6): system-managed, literal names (not in
  # the labels: mapping — state.sh also creates them on demand). Pre-created up
  # to this consumer's attempt_cap so they carry a color and description.
  local i cap; cap="$(config_attempt_cap)"
  i=1
  while [ "$i" -le "$cap" ]; do
    name="autofix-attempt-$i"
    desc="PR: consecutive CI auto-fix attempt $i (system-managed)"
    if [ "$DRY_RUN" -eq 1 ]; then printf 'DRY-RUN: label %s\n' "$name" >&2
    else
      gh label create "$name" --repo "$repo" --color f9d0c4 --description "$desc" 2>/dev/null \
        || gh label edit "$name" --repo "$repo" --color f9d0c4 --description "$desc" >/dev/null
    fi
    i=$((i + 1))
  done
  sh_log "✓ label vocabulary created/updated"
  ob_check ok "labels" "state axis + PR markers + category + attempt counters"
}

# docs/agents/triage-labels.md — the vocabulary reference a triage/grilling
# session reads (Pocock flow, ADR 0006 / 06-6). Lives in the agent-read-only
# knowledge layer. A Pocock repo already carries one (the triage skill's file):
# IMPORT it — keep the repo's own content and only append the system-owned-
# states note, the contract line that triage must never hand-apply loop states.
# A repo without one gets a generated doc from the same table create_labels
# uses (through the mapping), so it cannot drift from the actual labels.
TRIAGE_DOC_PATH="docs/agents/triage-labels.md"

_triage_note() {
  printf '\n## System-owned states\n\n'
  printf '`%s` and `%s` are applied and removed by the smallhours loop only.\n' \
    "$(label_for agent-working)" "$(label_for in-review)"
  printf 'Never hand-apply them during triage: removing or adding one by hand is\n'
  printf 'a signal to the system (cancellation / state drift), not bookkeeping.\n'
}

_triage_md() {
  local name color desc
  printf '# Triage labels\n\n'
  printf 'Label vocabulary for triaging/grilling issues in this repository.\n'
  printf 'Managed by smallhours setup — edit `.smallhours.yml` `labels:` to rename,\n'
  printf 'then re-run setup; do not edit this file by hand.\n\n'
  while IFS=$'\t' read -r name color desc; do
    [ -n "$name" ] || continue
    printf -- '- `%s` — %s\n' "$(label_for "$name")" "$desc"
  done < <(_labels)
  _triage_note
}

# Existing file (default branch) + note when missing, else the generated doc.
_triage_content() { # repo
  local existing
  existing="$(gh api "repos/$1/contents/$TRIAGE_DOC_PATH?ref=$DEFAULT_BRANCH" \
                --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    if printf '%s' "$existing" | grep -q '## System-owned states'; then
      printf '%s' "$existing"
    else
      printf '%s\n' "$existing"; _triage_note
    fi
  else
    _triage_md
  fi
}

# Emit a YAML scalar for a workflow name: plain when simple, single-quoted when
# it contains a space/special char — keeps the rendered file lint-clean either
# way (strict linters reject double quotes on a plain-able string).
_yaml_scalar() {
  case "$1" in
    *[!A-Za-z0-9_-]*) printf "'%s'" "$1" ;;
    *)                printf '%s' "$1" ;;
  esac
}

# Render a template with the CI workflow name substituted for the default `ci`
# token, so a hand-copied template still works unchanged.
_render() { # local-template -> stdout
  local s; s="$(_yaml_scalar "$CI_WORKFLOW")"
  sed -e "s|workflows: \[ci\]|workflows: [${s}]|" \
      -e "s|^ci_workflow: ci$|ci_workflow: ${s}|" "$1"
}

# Create-or-update a file on a branch via the contents API. `$(...)` strips the
# template's trailing newline, so printf re-adds exactly one (linters require a
# final newline).
_put_file() { # repo path content branch
  local repo="$1" path="$2" content="$3" branch="$4" sha b64 args
  sha="$(gh api "repos/$repo/contents/$path?ref=$branch" --jq .sha 2>/dev/null || true)"
  b64="$(printf '%s\n' "$content" | base64 | tr -d '\n')"
  args=(--method PUT "repos/$repo/contents/$path"
        -f "message=smallhours onboarding: $path"
        -f "content=$b64" -f "branch=$branch")
  [ -n "$sha" ] && args+=(-f "sha=$sha")
  gh api "${args[@]}" >/dev/null
}

# Does the default branch require a PR (ruleset OR legacy protection)? If so we
# cannot push onboarding files straight to it.
default_branch_protected() { # repo
  gh api "repos/$1/rules/branches/$DEFAULT_BRANCH" \
    --jq '[.[].type] | index("pull_request") != null' 2>/dev/null | grep -qx true
}

land_files() { # repo
  local repo="$1" stub cfg triage
  stub="$(_render "$_root/stub/agent-loop.yml")"
  cfg="$(_render "$_root/stub/.smallhours.yml")"
  triage="$(_triage_content "$repo")"
  if [ "$DRY_RUN" -eq 1 ]; then
    if default_branch_protected "$repo"; then
      sh_log "DRY-RUN: $DEFAULT_BRANCH requires PRs — would land stub + config + triage-labels.md via PR ($ONBOARD_BRANCH)"
    else
      sh_log "DRY-RUN: would push stub + config + triage-labels.md directly to $DEFAULT_BRANCH"
    fi
    return
  fi

  if ! default_branch_protected "$repo"; then
    _put_file "$repo" ".github/workflows/agent-loop.yml" "$stub"   "$DEFAULT_BRANCH"
    _put_file "$repo" ".smallhours.yml"                  "$cfg"    "$DEFAULT_BRANCH"
    _put_file "$repo" "$TRIAGE_DOC_PATH"                 "$triage" "$DEFAULT_BRANCH"
    sh_log "✓ pushed stub + config + triage-labels.md to $DEFAULT_BRANCH"
    ob_check ok "stub + config" "landed on $DEFAULT_BRANCH"
    return
  fi

  # Protected default branch: land via an onboarding PR. Do NOT force-reset the
  # branch ref if it already exists — that empties the branch and GitHub closes
  # the open PR. Create the branch only when absent; otherwise update files on
  # top (new commits), keeping the existing PR alive.
  local existing
  existing="$(gh pr list --repo "$repo" --head "$ONBOARD_BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if ! gh api "repos/$repo/git/refs/heads/$ONBOARD_BRANCH" >/dev/null 2>&1; then
    local base_sha; base_sha="$(gh api "repos/$repo/git/refs/heads/$DEFAULT_BRANCH" --jq .object.sha)"
    gh api --method POST "repos/$repo/git/refs" -f "ref=refs/heads/$ONBOARD_BRANCH" -f "sha=$base_sha" >/dev/null
  fi
  _put_file "$repo" ".github/workflows/agent-loop.yml" "$stub"   "$ONBOARD_BRANCH"
  _put_file "$repo" ".smallhours.yml"                  "$cfg"    "$ONBOARD_BRANCH"
  _put_file "$repo" "$TRIAGE_DOC_PATH"                 "$triage" "$ONBOARD_BRANCH"

  if [ -n "$existing" ]; then
    ONBOARD_PR="$existing"
    sh_log "✓ onboarding PR #$existing updated ($ONBOARD_BRANCH)"
  else
    gh pr create --repo "$repo" --base "$DEFAULT_BRANCH" --head "$ONBOARD_BRANCH" \
      --title "smallhours onboarding" \
      --body "Adds the smallhours consumer stub (\`.github/workflows/agent-loop.yml\`) + \`.smallhours.yml\`, wired to the \`${CI_WORKFLOW}\` workflow. Merge to activate the loop." >/dev/null
    ONBOARD_PR="$(gh pr list --repo "$repo" --head "$ONBOARD_BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
    sh_log "✓ opened onboarding PR ($ONBOARD_BRANCH → $DEFAULT_BRANCH) — REVIEW AND MERGE to activate the loop"
  fi
  ob_check warn "stub + config" "landed via PR #${ONBOARD_PR:-?} — merge it to activate the loop"
}

enable_secret_scanning() { # repo
  if [ "$DRY_RUN" -eq 1 ]; then sh_log "DRY-RUN: enable secret-scanning push protection"; return; fi
  if gh api --method PATCH "repos/$1" --input - >/dev/null <<'JSON'
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
JSON
  then
    sh_log "✓ secret-scanning push protection enabled"
    ob_check ok "secret-scanning push protection" "enabled"
  else
    sh_log "⚠ could not enable secret scanning — fix: repo Settings → Advanced Security (an org policy may own this toggle)"
    ob_check warn "secret-scanning push protection" "could not enable — fix: repo Settings → Advanced Security (org policy may own the toggle)"
  fi
}

# Auto-delete the head branch on merge — this is what deletes agent/issue-N when
# a PR merges (T8). Without it, merged agent branches linger.
enable_auto_delete_branch() { # repo
  if [ "$DRY_RUN" -eq 1 ]; then sh_log "DRY-RUN: enable delete-branch-on-merge"; return; fi
  if gh api --method PATCH "repos/$1" -F delete_branch_on_merge=true >/dev/null 2>&1; then
    sh_log "✓ auto-delete head branch on merge enabled (T8 branch cleanup)"
    ob_check ok "auto-delete merged branches" "enabled (T8 cleanup)"
  else
    sh_log "⚠ could not enable delete-branch-on-merge — fix: gh repo edit $1 --delete-branch-on-merge"
    ob_check warn "auto-delete merged branches" "could not enable — fix: gh repo edit $1 --delete-branch-on-merge"
  fi
}

set_branch_protection() { # repo
  local repo="$1"
  if [ "$SKIP_PROTECTION" -eq 1 ]; then
    sh_log "skipping branch protection (--skip-protection)"
    ob_check warn "branch protection" "skipped by flag — the human-approval gate is OFF; re-run without --skip-protection"
    return
  fi
  if default_branch_protected "$repo"; then
    sh_log "✓ $DEFAULT_BRANCH already requires PRs (ruleset/legacy) — leaving existing protection as-is"
    ob_check ok "branch protection" "$DEFAULT_BRANCH already requires PRs (existing rules kept)"
    return
  fi
  # Required check contexts. Auto-detection is best-effort: check-run names are
  # job names, not the workflow name, so we cannot reliably map them — pass
  # --required-checks to be precise. Empty = protect without a required check
  # (never require a context that will not report and strand every merge).
  local ctx
  if [ -n "$REQUIRED_CHECKS" ]; then
    ctx="$(printf '%s' "$REQUIRED_CHECKS" | jq -R 'split(",")')"
  else
    ctx='[]'
    local avail
    avail="$(gh api "repos/$repo/commits/$DEFAULT_BRANCH/check-runs" --jq '[.check_runs[].name] | unique | join(", ")' 2>/dev/null || true)"
    [ -n "$avail" ] && sh_log "⚠ not requiring a specific CI check. Available checks: ${avail}. Re-run with --required-checks \"...\" to enforce one."
  fi
  if [ "$DRY_RUN" -eq 1 ]; then sh_log "DRY-RUN: set legacy branch protection on $DEFAULT_BRANCH, checks=$ctx"; return; fi
  jq -n --argjson contexts "$ctx" '{
    required_status_checks: { strict: true, contexts: $contexts },
    enforce_admins: false,
    required_pull_request_reviews: { required_approving_review_count: 1 },
    restrictions: null
  }' | gh api --method PUT "repos/$repo/branches/$DEFAULT_BRANCH/protection" --input - >/dev/null
  sh_log "✓ branch protection: PR required, 1 approval, up-to-date, checks=$ctx"
  ob_check ok "branch protection" "PR required, 1 approval, up-to-date, checks=$ctx"
}

# The ending checklist (M8): setup always closes with met/unmet + remedies,
# and the onboarding PR (when landing went via PR) mirrors it — the reviewer
# merging that PR sees the same list the terminal showed.
print_checklist() { # repo
  echo >&2
  printf 'smallhours onboarding checklist — %s\n' "$1" >&2
  ob_checklist_render >&2
  if [ "$(ob_checklist_unmet)" -gt 0 ]; then
    printf '%s unmet — run the fixes above, then verify with setup/doctor.sh %s\n' "$(ob_checklist_unmet)" "$1" >&2
  fi
}

mirror_checklist_to_pr() { # repo
  [ -n "$ONBOARD_PR" ] || return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  local body
  body="$(printf 'Adds the smallhours consumer stub (`.github/workflows/agent-loop.yml`) + `.smallhours.yml`, wired to the `%s` workflow. Merge to activate the loop.\n\n## Onboarding checklist\n\n%s\n\nUnchecked items have their remedy inline; `setup/doctor.sh %s` re-verifies everything.' \
            "$CI_WORKFLOW" "$(ob_checklist_markdown)" "$1")"
  gh pr edit "$ONBOARD_PR" --repo "$1" --body "$body" >/dev/null \
    || sh_log "⚠ could not mirror the checklist onto PR #$ONBOARD_PR — fix: re-run setup-repo.sh $1 (idempotent), or paste the checklist below into the PR by hand"
}

usage() { echo "usage: setup-repo.sh <owner/repo> [--ci-workflow NAME] [--required-checks a,b] [--skip-protection] [--dry-run]" >&2; }

main() {
  local repo=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ci-workflow)     CI_WORKFLOW="$2"; shift 2 ;;
      --required-checks) REQUIRED_CHECKS="$2"; shift 2 ;;
      --skip-protection) SKIP_PROTECTION=1; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      -*)                usage; exit 64 ;;
      *)                 [ -z "$repo" ] && repo="$1" || { usage; exit 64; }; shift ;;
    esac
  done
  [ -n "$repo" ] || { usage; exit 64; }

  preflight "$repo"
  load_consumer_config "$repo"
  ob_checklist_reset
  # Setup ALWAYS ends with the checklist (M8): a mid-run die still prints
  # whatever was established up to that point, remedies included.
  trap 'print_checklist "'"$repo"'"' EXIT
  verify_secrets "$repo"
  detect_ci_workflow "$repo"
  create_labels "$repo"
  land_files "$repo"
  enable_secret_scanning "$repo"
  enable_auto_delete_branch "$repo"
  set_branch_protection "$repo"
  mirror_checklist_to_pr "$repo"

  sh_log "onboarding complete for $repo"
  sh_log "next: merge the onboarding PR (if any), then run the canary — docs/GETTING-STARTED.md#6-first-run-the-canary"
}

main "$@"
