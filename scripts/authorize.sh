#!/usr/bin/env bash
# authorize.sh — T1 gate. The ONLY thing standing between "someone applied
# ready-for-agent" and spending tokens. FAIL-CLOSED: if the labeller does not
# have write access, strip the trigger and stop.
#
#   authorize.sh <issue-number> <actor-login>
#
# Grant: leave the issue `ready-for-agent` (validated + QUEUED), exit 0. The
#        dispatcher (dispatch.sh) later promotes it to `agent-working` when a
#        concurrency slot is free — authorize no longer starts work itself.
# Deny:  issue -> needs-triage, comment, exit 3 (caller must stop).
#
# Env: GH_TOKEN, GITHUB_REPOSITORY (or a resolvable gh repo).
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/state.sh"

main() {
  [ "$#" -eq 2 ] || sh_die "usage: authorize.sh <issue-number> <actor-login>"
  local issue="$1" actor="$2" repo perm
  repo="$(sh_repo)"
  sh_require_auth

  # admin / maintain / write may authorize; read / none / triage may not.
  perm="$(gh api "repos/$repo/collaborators/$actor/permission" --jq '.permission' 2>/dev/null || echo none)"
  case "$perm" in
    admin|maintain|write)
      # Validated. Leave it queued (ready-for-agent); the dispatcher starts it
      # when a slot frees. Do NOT set agent-working here.
      sh_log "authorize: $actor has '$perm' on $repo — granted, issue #$issue queued"
      exit 0
      ;;
    *)
      sh_log "authorize: $actor has '$perm' — DENIED, fail-closed"
      # Remove the trigger by moving to a triage state (keeps the exactly-one
      # invariant; a bare label removal would leave the issue state-less).
      state_set_issue "$issue" needs-triage
      sh_comment_issue "$issue" \
        "🔒 \`ready-for-agent\` was applied by @${actor}, who does not have write access to this repository, so smallhours did not act. Moved back to \`needs-triage\`. A maintainer can re-apply the label."
      exit 3
      ;;
  esac
}

main "$@"
