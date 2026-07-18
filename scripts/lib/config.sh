#!/usr/bin/env bash
# lib/config.sh — load consumer config (.smallhours.yml) over baked-in defaults,
# and expose the canonical label vocabulary + per-stage model / max-turns.
#
# Source this; do not execute. Portability contract (ADR 0001/0002): only bash,
# gh, jq, and yq (ADR 0004). No YAML is parsed by hand — yq converts once to
# JSON and every getter reads that JSON with jq.
#
# Every .smallhours.yml key is OPTIONAL; missing keys fall through to the
# defaults defined here (DESIGN.md "Stage configuration").
#
# Env:
#   SMALLHOURS_CONFIG   path to the config file (default: ./.smallhours.yml,
#                       or $GITHUB_WORKSPACE/.smallhours.yml when set)
# Provides:
#   config_load                       parse config once (idempotent)
#   config_model <stage>              e.g. config_model implement
#   config_max_turns <stage>          e.g. config_max_turns address_review
#   config_attempt_cap
#   config_ci_workflow
#   config_egress_extra_domains       one domain per line
#   config_npm_allowed                prints "true"/"false"
#   Label constants + helpers (see below).

# Guard against double-sourcing.
[ -n "${_SMALLHOURS_CONFIG_SH:-}" ] && return 0
_SMALLHOURS_CONFIG_SH=1

# ── Canonical label vocabulary (CONTEXT.md) ───────────────────────────────────
# Issue STATE axis — exactly one per triaged issue at all times.
SMALLHOURS_STATE_LABELS=(
  needs-triage needs-info ready-for-agent ready-for-human wontfix
  agent-working in-review
)
# PR marker labels — ownership + situational, never a second state axis.
SMALLHOURS_PR_LABELS=(agent ci-failing ready-to-merge human-needed)
# Category axis — applied during grilling, used as-is.
SMALLHOURS_CATEGORY_LABELS=(bug enhancement)

# ── Defaults (DESIGN.md) ──────────────────────────────────────────────────────
_sh_default_model()     { echo "claude-sonnet-5"; }
_sh_default_max_turns() {
  case "$1" in
    implement)        echo 50 ;;
    address_review)   echo 30 ;;
    auto_fix)         echo 25 ;;
    resolve_conflict) echo 20 ;;
    *)                echo 30 ;;
  esac
}
_SH_DEFAULT_ATTEMPT_CAP=3
_SH_DEFAULT_CI_WORKFLOW=ci
_SH_DEFAULT_NPM_ALLOWED=false

# Populated by config_load with the config-as-JSON, or "{}" when no file exists.
_SH_CONFIG_JSON=""

# Resolve the config path once.
_sh_config_path() {
  if [ -n "${SMALLHOURS_CONFIG:-}" ]; then
    echo "$SMALLHOURS_CONFIG"
  elif [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "$GITHUB_WORKSPACE/.smallhours.yml" ]; then
    echo "$GITHUB_WORKSPACE/.smallhours.yml"
  else
    echo "./.smallhours.yml"
  fi
}

config_load() {
  [ -n "${_SH_CONFIG_JSON:-}" ] && return 0
  local path; path="$(_sh_config_path)"
  if [ -f "$path" ]; then
    # One yq call; everything downstream is jq. Fail loudly rather than let a
    # present-but-broken config silently run every stage on defaults. Callers
    # that depend on config invoke config_load eagerly so this aborts up front.
    if ! command -v yq >/dev/null 2>&1; then
      echo "smallhours: yq not found on PATH — required to read '$path' (see versions.env / ADR 0004)" >&2
      return 1
    fi
    if ! _SH_CONFIG_JSON="$(yq -o=json '.' "$path" 2>/dev/null)"; then
      echo "smallhours: config at '$path' is present but not valid YAML" >&2
      return 1
    fi
    [ -n "$_SH_CONFIG_JSON" ] || _SH_CONFIG_JSON="{}"
  else
    # No file is the normal path — every key is optional, defaults apply.
    _SH_CONFIG_JSON="{}"
  fi
  return 0
}

# jq getter against the loaded config; prints nothing (empty) when the key is
# absent or null, so callers can `|| default`.
_sh_get() { # jq-filter
  config_load || return 1
  printf '%s' "$_SH_CONFIG_JSON" | jq -r "$1 // empty"
}

config_model() { # stage
  local v; v="$(_sh_get ".models.$1")"
  [ -n "$v" ] && echo "$v" || _sh_default_model "$1"
}

config_max_turns() { # stage
  local v; v="$(_sh_get ".max_turns.$1")"
  [ -n "$v" ] && echo "$v" || _sh_default_max_turns "$1"
}

config_attempt_cap() {
  local v; v="$(_sh_get '.attempt_cap')"
  [ -n "$v" ] && echo "$v" || echo "$_SH_DEFAULT_ATTEMPT_CAP"
}

config_ci_workflow() {
  local v; v="$(_sh_get '.ci_workflow')"
  [ -n "$v" ] && echo "$v" || echo "$_SH_DEFAULT_CI_WORKFLOW"
}

# One domain per line (may be empty).
config_egress_extra_domains() {
  config_load || return 1
  printf '%s' "$_SH_CONFIG_JSON" | jq -r '.egress_extra_domains // [] | .[]'
}

config_npm_allowed() {
  local v; v="$(_sh_get '.npm_allowed')"
  [ -n "$v" ] && echo "$v" || echo "$_SH_DEFAULT_NPM_ALLOWED"
}
