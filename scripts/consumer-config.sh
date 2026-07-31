#!/usr/bin/env bash
# consumer-config.sh — install the pinned yq and (optionally) fetch the
# consumer's .smallhours.yml into $RUNNER_TEMP/smallhours-config.yml.
#
#   consumer-config.sh [--no-fetch-config]
#
# Env: GH_TOKEN (reads the consumer config via the API), RUNNER_TEMP.
#
# Runs from the toolkit's own checkout, so it is always at the exact invoked
# toolkit version (job.workflow_sha) — no separate versioning surface.
#
# This was a composite action (`uses: ./.smallhours-toolkit/.github/actions/…`)
# until ADR 0010 moved the toolkit checkout out of the consumer worktree. Local
# action paths resolve against $GITHUB_WORKSPACE and `uses:` accepts no
# expressions, so an out-of-workspace toolkit cannot be referenced that way at
# all. A script invoked by absolute path keeps the single definition the
# `config-fetch-step-duplicated` debt paid for.
#
# Jobs that check out the consumer repo pass --no-fetch-config and read
# .smallhours.yml from the workspace (lib/config.sh's default path); jobs
# without a consumer checkout take the fetch and export
# SMALLHOURS_CONFIG=$RUNNER_TEMP/smallhours-config.yml themselves.
set -euo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fetch_config=true
case "${1:-}" in
  --no-fetch-config) fetch_config=false ;;
  '') ;;
  *) echo "usage: consumer-config.sh [--no-fetch-config]" >&2; exit 2 ;;
esac

# versions.env sits at the toolkit root, one level up from scripts/.
# shellcheck source=../versions.env
. "$_dir/../versions.env"

curl -fsSL -o "$RUNNER_TEMP/yq" \
  "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"
sudo install -m 0755 "$RUNNER_TEMP/yq" /usr/local/bin/yq

if [ "$fetch_config" = true ]; then
  gh api "repos/${GITHUB_REPOSITORY}/contents/.smallhours.yml" \
    --jq '.content' 2>/dev/null | base64 -d > "$RUNNER_TEMP/smallhours-config.yml" || true
fi
