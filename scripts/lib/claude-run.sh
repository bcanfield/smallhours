#!/usr/bin/env bash
# lib/claude-run.sh — the ONLY place Claude Code is invoked. Encodes the shipped
# security posture from ADR 0001 (and its spike-0a addendum): run under the
# native bubblewrap sandbox with `--permission-mode acceptEdits`, NEVER
# `--dangerously-skip-permissions` (which disables the very sandbox). Source
# this; do not execute.
#
# Three responsibilities (plan M2):
#   1. render managed settings from config (egress allowlist + npm posture)
#   2. provision the sandbox runtime on the runner  (claude_run_provision)
#   3. run a stage and capture the JSON result       (claude_run)
#
# GIVE-UP SEMANTICS (risk register): a CLI failure — non-zero exit OR
# is_error:true in the result — is a give-up, surfaced as a non-zero return so
# the caller routes the issue to ready-for-human. This layer NEVER retries.
#
# Depends on lib/config.sh (models, max-turns, egress, npm) + lib/common.sh.

[ -n "${_SMALLHOURS_CLAUDE_RUN_SH:-}" ] && return 0
_SMALLHOURS_CLAUDE_RUN_SH=1

_sh_cr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$_sh_cr_dir/config.sh"
# shellcheck source=./common.sh
. "$_sh_cr_dir/common.sh"

_SH_MANAGED_SETTINGS_PATH="${SMALLHOURS_MANAGED_SETTINGS_PATH:-/etc/claude-code/managed-settings.json}"

# Base egress allowlist — GitHub + Anthropic only (spike 0a profile-hardened).
_SH_BASE_DOMAINS=(
  github.com "*.github.com" "*.githubusercontent.com"
  api.anthropic.com "*.anthropic.com"
)

# Print the managed-settings JSON for this consumer: the hardened profile with
# allowedDomains = base + egress_extra_domains (+ npm registry when npm_allowed).
# WebFetch/WebSearch stay denied (sandbox.network covers Bash only — addendum
# finding 2); allowManagedPermissionRulesOnly stops a consumer's own settings
# re-allowing them.
claude_run_render_settings() {
  local domains=("${_SH_BASE_DOMAINS[@]}") d
  while IFS= read -r d; do [ -n "$d" ] && domains+=("$d"); done < <(config_egress_extra_domains)

  local ignore_scripts="false"
  if [ "$(config_npm_allowed)" = "true" ]; then
    # npm permitted: reach the registry, but never run install lifecycle
    # scripts (arbitrary code on `npm install`).
    domains+=("registry.npmjs.org")
    ignore_scripts="true"
  fi

  local domains_json
  domains_json="$(printf '%s\n' "${domains[@]}" | jq -R . | jq -s .)"

  jq -n --argjson domains "$domains_json" --arg ignore_scripts "$ignore_scripts" '{
    env: { DISABLE_AUTOUPDATER: "1", NPM_CONFIG_IGNORE_SCRIPTS: $ignore_scripts },
    permissions: { deny: ["WebFetch", "WebSearch"] },
    allowManagedPermissionRulesOnly: true,
    allowManagedHooksOnly: true,
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      autoAllowBashIfSandboxed: true,
      allowUnsandboxedCommands: false,
      allowManagedDomainsOnly: true,
      excludedCommands: [],
      enableWeakerNestedSandbox: false,
      network: {
        allowedDomains: $domains,
        allowUnixSockets: [],
        allowAllUnixSockets: false,
        allowLocalBinding: false
      }
    }
  }'
}

# Write the managed settings to the managed scope (needs root for the default
# /etc path). Idempotent.
claude_run_install_settings() {
  local dir; dir="$(dirname "$_SH_MANAGED_SETTINGS_PATH")"
  local sudo=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && sudo="sudo"
  $sudo install -d -m 0755 "$dir"
  claude_run_render_settings | $sudo tee "$_SH_MANAGED_SETTINGS_PATH" >/dev/null
  sh_log "managed settings installed at $_SH_MANAGED_SETTINGS_PATH"
}

# Provision the sandbox runtime on a Debian/Ubuntu runner (mirrors spike 0a).
# Debian/Ubuntu + sudo targeted; on any other environment it explains and skips,
# so a self-hosted image that bakes these in isn't fought. Idempotent.
claude_run_provision() {
  if ! command -v apt-get >/dev/null; then
    sh_log "provision: not a Debian/Ubuntu host — assuming the runtime image \
provides bubblewrap, the AppArmor profile, claude, and sandbox-runtime. Skipping."
    return 0
  fi
  local sudo=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && sudo="sudo"

  sh_log "provision: bubblewrap + socat"
  $sudo apt-get update -qq
  $sudo apt-get install -y --no-install-recommends bubblewrap socat

  # Ubuntu 24.04+ restricts unprivileged user namespaces; bwrap needs the
  # AppArmor profile from the Claude Code docs or it cannot isolate (addendum
  # finding 3). Conditional on the sysctl so it's a no-op elsewhere.
  if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
    sh_log "provision: installing bwrap AppArmor profile (userns restricted)"
    $sudo tee /etc/apparmor.d/bwrap >/dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF
    $sudo systemctl reload apparmor
  fi

  if ! command -v claude >/dev/null; then
    sh_log "provision: Claude Code ${CLAUDE_CODE_VERSION:-<version from versions.env>}"
    curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION:?set CLAUDE_CODE_VERSION from versions.env}"
    export PATH="$HOME/.local/bin:$PATH"
    [ -n "${GITHUB_PATH:-}" ] && echo "$HOME/.local/bin" >> "$GITHUB_PATH"
  fi

  # Seccomp filter that blocks Unix-socket sandbox escapes.
  command -v srt >/dev/null 2>&1 || npm install -g @anthropic-ai/sandbox-runtime

  claude_run_install_settings
}

# Run one stage. Returns 0 on a clean result, non-zero on give-up.
#   claude_run <stage> <prompt_file> <out_json>
# stage ∈ implement | address_review | auto_fix | resolve_conflict
# Requires CLAUDE_CODE_OAUTH_TOKEN in the environment.
claude_run() {
  local stage="$1" prompt_file="$2" out="$3"
  [ -f "$prompt_file" ] || sh_die "claude_run: prompt file not found: $prompt_file"
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || sh_die "claude_run: CLAUDE_CODE_OAUTH_TOKEN not set"

  local model max_turns
  model="$(config_model "$stage")"
  max_turns="$(config_max_turns "$stage")"
  sh_log "claude_run: stage=$stage model=$model max_turns=$max_turns"

  local rc=0
  claude -p \
    --permission-mode acceptEdits \
    --model "$model" \
    --max-turns "$max_turns" \
    --output-format json \
    < "$prompt_file" > "$out" 2> "$out.stderr" || rc=$?

  if [ "$rc" -ne 0 ]; then
    # Surface the failure INTO the job log: the runner's temp dir (and the
    # stderr file with the real reason — quota, crash, denial) dies with the
    # runner, so a path reference alone loses the root cause forever.
    sh_log "claude_run: CLI exited $rc — give-up. stderr tail:"
    tail -n 20 "${out}.stderr" >&2 2>/dev/null || true
    if [ -s "$out" ]; then
      sh_log "claude_run: partial result JSON (subtype/is_error): $(jq -rc '{subtype, is_error} // empty' "$out" 2>/dev/null || true)"
    else
      sh_log "claude_run: no result JSON was written"
    fi
    return "$rc"
  fi
  if [ "$(claude_is_error "$out")" = "true" ]; then
    sh_log "claude_run: result is_error=true — give-up. result subtype: $(claude_result_field "$out" '.subtype')"
    return 1
  fi
  return 0
}

# ── Result accessors (claude -p --output-format json shape) ───────────────────
claude_result_field() { jq -r "$2 // empty" "$1" 2>/dev/null; }  # out_json jq-path
claude_is_error()     { claude_result_field "$1" '.is_error' ; }
claude_num_turns()    { claude_result_field "$1" '.num_turns' ; }
claude_duration_ms()  { claude_result_field "$1" '.duration_ms' ; }
claude_result_text()  { claude_result_field "$1" '.result' ; }
