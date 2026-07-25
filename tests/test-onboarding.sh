#!/usr/bin/env bash
# test-onboarding.sh — tests for lib/onboarding.sh pure helpers (Milestone 8):
# the App-manifest JSON create-app.sh submits, the callback-code parser, and
# the ending-checklist renderer. Pure logic only (jq, no gh, no network).
# Run: tests/test-onboarding.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/../scripts/lib/onboarding.sh"

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "  ok: $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

case_banner "manifest JSON carries the Fixer permission set, nothing extra"
m="$(ob_manifest_json my-fixer "https://github.com/o/r" "http://127.0.0.1:8237/callback")"
[ "$(printf '%s' "$m" | jq -r '.default_permissions.contents')" = "write" ] \
  && ok "contents: write" || bad "contents permission wrong"
[ "$(printf '%s' "$m" | jq -r '.default_permissions.issues')" = "write" ] \
  && ok "issues: write" || bad "issues permission wrong"
[ "$(printf '%s' "$m" | jq -r '.default_permissions.pull_requests')" = "write" ] \
  && ok "pull_requests: write" || bad "pull_requests permission wrong"
[ "$(printf '%s' "$m" | jq -r '.default_permissions.actions')" = "read" ] \
  && ok "actions: read" || bad "actions permission wrong"
[ "$(printf '%s' "$m" | jq '.default_permissions | length')" = "4" ] \
  && ok "exactly 4 permissions" || bad "unexpected extra permissions"

case_banner "manifest keeps the webhook OFF (the onboarding tripwire)"
[ "$(printf '%s' "$m" | jq 'has("hook_attributes")')" = "false" ] \
  && ok "no hook_attributes key" || bad "hook_attributes present — webhook would need a URL"
[ "$(printf '%s' "$m" | jq '.default_events // [] | length')" = "0" ] \
  && ok "no webhook events subscribed" || bad "default_events non-empty"

case_banner "manifest identity fields"
[ "$(printf '%s' "$m" | jq -r '.name')" = "my-fixer" ] \
  && ok "name passed through" || bad "name wrong"
[ "$(printf '%s' "$m" | jq -r '.public')" = "false" ] \
  && ok "app is private to its owner" || bad "public should be false"
[ "$(printf '%s' "$m" | jq -r '.redirect_url')" = "http://127.0.0.1:8237/callback" ] \
  && ok "redirect_url passed through" || bad "redirect_url wrong"
[ "$(printf '%s' "$m" | jq -r '.url')" = "https://github.com/o/r" ] \
  && ok "homepage url passed through" || bad "url wrong"

case_banner "manifest POST target: personal vs --org"
[ "$(ob_manifest_post_url "")" = "https://github.com/settings/apps/new" ] \
  && ok "personal account URL" || bad "personal URL wrong"
[ "$(ob_manifest_post_url "acme")" = "https://github.com/organizations/acme/settings/apps/new" ] \
  && ok "org URL" || bad "org URL wrong"

case_banner "callback code extraction from the HTTP request line"
[ "$(ob_code_from_request 'GET /callback?code=a180b1a3d263 HTTP/1.1')" = "a180b1a3d263" ] \
  && ok "bare code" || bad "bare code not extracted"
[ "$(ob_code_from_request 'GET /callback?code=abc123&state=xyz HTTP/1.1')" = "abc123" ] \
  && ok "code with trailing params" || bad "trailing params leaked into code"
[ "$(ob_code_from_request 'GET /callback?state=xyz&code=abc123 HTTP/1.1')" = "abc123" ] \
  && ok "code after other params" || bad "leading params broke extraction"
[ -z "$(ob_code_from_request 'GET /favicon.ico HTTP/1.1')" ] \
  && ok "no code -> empty" || bad "phantom code extracted"

case_banner "checklist accumulates and renders met/unmet"
ob_checklist_reset
ob_check ok   "secrets"   "all three present"
ob_check fail "App install" "run setup/create-app.sh <owner/repo>"
ob_check warn "protection" "re-run without --skip-protection"
r="$(ob_checklist_render)"
printf '%s\n' "$r" | grep -q '✓ secrets — all three present' \
  && ok "met item renders ✓" || bad "met item wrong: $r"
printf '%s\n' "$r" | grep -q '✗ App install — run setup/create-app.sh <owner/repo>' \
  && ok "unmet item renders ✗ + remedy" || bad "unmet item wrong"
printf '%s\n' "$r" | grep -q '⚠ protection — re-run without --skip-protection' \
  && ok "warn item renders ⚠" || bad "warn item wrong"

case_banner "checklist markdown mirror (onboarding PR body)"
md="$(ob_checklist_markdown)"
printf '%s\n' "$md" | grep -q -- '- \[x\] secrets — all three present' \
  && ok "met item -> checked box" || bad "markdown met item wrong"
printf '%s\n' "$md" | grep -q -- '- \[ \] App install — run setup/create-app.sh <owner/repo>' \
  && ok "unmet item -> unchecked box + remedy" || bad "markdown unmet item wrong"

case_banner "checklist unmet count drives exit disposition"
[ "$(ob_checklist_unmet)" = "1" ] \
  && ok "one unmet (warn does not count)" || bad "unmet count wrong: $(ob_checklist_unmet)"
ob_checklist_reset
[ "$(ob_checklist_unmet)" = "0" ] \
  && ok "reset clears the list" || bad "reset did not clear"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
