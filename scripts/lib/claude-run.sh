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

  # stream-json is the only format that emits per-turn tool-use events;
  # --output-format json buffers the whole run into one final object, so what
  # the agent actually did (which files, how many bash calls) was never
  # visible even after claude_result_digest (the mediamtx-connect#213/#207
  # follow-up: the turn count alone doesn't say whether a run was doing real
  # work or spinning). The terminal event still carries the exact same
  # {subtype, is_error, num_turns, ...} shape json would have written —
  # extracted into $out below so every downstream reader keeps working
  # unmodified. --verbose is required by the CLI alongside stream-json in
  # --print mode.
  local stream="${out}.stream"
  local rc=0
  claude -p \
    --permission-mode acceptEdits \
    --model "$model" \
    --max-turns "$max_turns" \
    --output-format stream-json --verbose \
    < "$prompt_file" > "$stream" 2> "$out.stderr" || rc=$?

  jq -c 'select(.type == "result")' "$stream" 2>/dev/null | tail -n1 > "$out"

  # Tool-call histogram + files touched + bash commands run: the only
  # surviving evidence of *what the agent did*, derived here and logged on
  # every run (clean or give-up) — a fast, uneventful run is exactly as worth
  # seeing as a give-up. The raw stream can carry file contents and command
  # output, so only these derived counts and paths are kept; the stream file
  # itself is discarded before this function returns, never uploaded.
  local work; work="$(claude_work_digest "$stream")"
  : > "${out}.work"; [ -n "$work" ] && printf '%s\n' "$work" > "${out}.work"
  rm -f "$stream"
  sh_log "claude_run: stage=$stage work: $(claude_work_summary "${out}.work")"

  if [ "$rc" -ne 0 ]; then
    # Surface the failure INTO the job log: the runner's temp dir (and the
    # stderr file with the real reason — quota, crash, denial) dies with the
    # runner, so a path reference alone loses the root cause forever.
    # stream-json still buffers to stdout until the process exits, so on an
    # error_max_turns give-up the stderr tail is empty and this digest is the
    # only surviving evidence — hence the counters, not just the subtype.
    sh_log "claude_run: CLI exited $rc — give-up. stderr tail:"
    tail -n 20 "${out}.stderr" >&2 2>/dev/null || true
    if [ -s "$out" ]; then
      sh_log "claude_run: result (max_turns=$max_turns): $(claude_result_digest "$out")"
    else
      sh_log "claude_run: no result JSON was written"
    fi
    return "$rc"
  fi
  if [ "$(claude_is_error "$out")" = "true" ]; then
    sh_log "claude_run: result is_error=true — give-up. result (max_turns=$max_turns): $(claude_result_digest "$out")"
    return 1
  fi
  return 0
}

# ── Result accessors (the terminal `type:"result"` event's shape) ─────────────
claude_result_field() { jq -r "$2 // empty" "$1" 2>/dev/null; }  # out_json jq-path
claude_is_error()     { claude_result_field "$1" '.is_error' ; }
claude_num_turns()    { claude_result_field "$1" '.num_turns' ; }
claude_duration_ms()  { claude_result_field "$1" '.duration_ms' ; }
claude_result_text()  { claude_result_field "$1" '.result' ; }

# One-line diagnostic digest for the job log. Deliberately excludes `.result`
# (the agent's own summary): that can be long, and the give-up path already
# posts it to the issue. Null fields are dropped, since an aborted run may
# write only some of them. "50/50 turns" and "died on turn 3" are the same
# give-up until this line tells them apart.
claude_result_digest() { # out_json
  jq -rc '{subtype, is_error, num_turns, duration_ms, total_cost_usd,
           input_tokens:  .usage.input_tokens,
           output_tokens: .usage.output_tokens}
          | with_entries(select(.value != null))' "$1" 2>/dev/null || true
}

# Derive a tool-use digest from a stream-json event log: how many times each
# tool was called, which files got Edit/Write/NotebookEdit'd, and which Bash
# commands ran. This is the answer to "was it doing real work or spinning" —
# --output-format json alone cannot say. Lists are capped (30 files, 20
# commands) with an accompanying _total so a cap never reads as a full count;
# only paths/commands survive, never tool input bodies or output content.
claude_work_digest() { # stream_jsonl -> {tool_counts, files_touched(+_total), bash_commands(+_total)}
  jq -cs '
    [ .[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") ] as $uses
    | ( [$uses[] | select(.name=="Bash") | .input.command // empty] | unique ) as $cmds
    | ( [$uses[] | select(.name=="Edit" or .name=="Write" or .name=="NotebookEdit") | .input.file_path // empty] | unique ) as $files
    | {
        tool_counts: ($uses | group_by(.name) | map({key: .[0].name, value: length}) | from_entries),
        files_touched: ($files | sort | .[0:30]),
        files_touched_total: ($files | length),
        bash_commands: ($cmds | sort | .[0:20]),
        bash_commands_total: ($cmds | length)
      }
  ' "$1" 2>/dev/null || true
}

# One-line rendering of claude_work_digest's output, for job logs and
# give-up/usage comments. Degrades quietly on a missing/empty/malformed
# digest file (same contract as claude_result_digest) rather than breaking
# the caller that's usually reporting a give-up already.
claude_work_summary() { # work_digest_json_file
  [ -s "$1" ] || { printf 'no tool-use data captured'; return; }
  jq -r '
    (.tool_counts // {} | to_entries | sort_by(-.value) | map("\(.key)×\(.value)") | join(" ")) as $tools
    | "tools: \($tools | if . == "" then "none" else . end) · files touched: \(.files_touched_total // 0) · bash commands: \(.bash_commands_total // 0)"
  ' "$1" 2>/dev/null || printf 'no tool-use data captured'
}
