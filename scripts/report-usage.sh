#!/usr/bin/env bash
# report-usage.sh — post the per-run usage comment on a PR (turns, duration,
# stage). DESIGN: every agent run posts one of these. Reads the JSON that
# claude_run captured (claude -p --output-format json).
#
#   report-usage.sh <pr-number> <result-json> <stage>
#
# Env: GH_TOKEN, GITHUB_REPOSITORY.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_dir/lib/common.sh"
. "$_dir/lib/claude-run.sh"

_fmt_duration() { # milliseconds -> "1m3s" / "8s"
  local ms="${1:-}"
  [ -n "$ms" ] || { printf 'unknown'; return; }
  local s=$(( ms / 1000 ))
  if [ "$s" -ge 60 ]; then printf '%dm%ds' $(( s / 60 )) $(( s % 60 ));
  else printf '%ds' "$s"; fi
}

main() {
  [ "$#" -eq 3 ] || sh_die "usage: report-usage.sh <pr-number> <result-json> <stage>"
  local pr="$1" json="$2" stage="$3"
  sh_require_auth
  [ -s "$json" ] || { sh_log "report-usage: $json missing/empty — nothing to report"; exit 0; }

  local turns dur
  turns="$(claude_num_turns "$json")"; [ -n "$turns" ] || turns="unknown"
  dur="$(_fmt_duration "$(claude_duration_ms "$json")")"

  sh_comment_pr "$pr" "🤖 **smallhours · ${stage}** — ${turns} turns · ${dur}"
}

main "$@"
