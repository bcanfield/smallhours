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
#   label_for <canonical>             repo label string for a canonical name
#   state_labels_resolved             resolved state axis, one per line
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

# Labels the reusable workflow gates on in expression-time `if:` clauses, where
# consumer config cannot be read. Remapping any of these is rejected at
# config_load (fail loud, never a silently dead trigger). v1 constraint — see
# docs/debt trigger-labels-not-mappable.
SMALLHOURS_FIXED_LABELS=(ready-for-agent agent-working agent)

# ── Defaults (DESIGN.md) ──────────────────────────────────────────────────────
_sh_default_model()     { echo "claude-sonnet-5"; }
# Raised 2026-07-29 from the mediamtx-connect rollout, which spent three days
# ratcheting these live (implement 50 -> 75 -> 100) through six give-ups. The
# evidence: implement runs that SUCCEEDED took 52, 73 and 76 turns, and the
# ones that gave up did so one turn over the cap, not while spinning — the
# originals were simply set below what real issues cost. auto_fix hit its own
# cap once at 26/25. A cap is a backstop against a runaway agent, so it should
# sit above real work rather than through the middle of it; the spend ceiling
# these were standing in for belongs to attempt_cap and max_concurrent.
# address_review/resolve_conflict are UNCHANGED — neither has been observed
# near its cap, and raising them on the strength of implement's evidence would
# be guessing.
_sh_default_max_turns() {
  case "$1" in
    implement)        echo 100 ;;
    address_review)   echo 30 ;;
    auto_fix)         echo 40 ;;
    resolve_conflict) echo 20 ;;
    *)                echo 30 ;;
  esac
}
_SH_DEFAULT_ATTEMPT_CAP=3
_SH_DEFAULT_CI_WORKFLOW=ci
_SH_DEFAULT_NPM_ALLOWED=false
# Max issues in `agent-working` at once (the WIP cap the dispatcher enforces).
# ready-for-agent is an unbounded queue; only this many run concurrently.
_SH_DEFAULT_MAX_CONCURRENT=3

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
    # On a rejected mapping, drop the parsed JSON — a cached bad config must
    # not answer later label_for calls as if it had loaded.
    _sh_labels_validate || { _SH_CONFIG_JSON=""; return 1; }
  else
    # No file is the normal path — every key is optional, defaults apply.
    _SH_CONFIG_JSON="{}"
  fi
  return 0
}

# Is $1 a canonical label name (any axis)?
_sh_is_canonical_label() {
  local l
  for l in "${SMALLHOURS_STATE_LABELS[@]}" "${SMALLHOURS_PR_LABELS[@]}" \
           "${SMALLHOURS_CATEGORY_LABELS[@]}"; do
    [ "$l" = "$1" ] && return 0
  done
  return 1
}

# Validate the labels: mapping at load time so a broken mapping aborts every
# stage up front instead of half-applying (fail-loud, same posture as a broken
# YAML file). Checks: keys are canonical names; the workflow-gated labels are
# not remapped; no two canonical names resolve to the same repo string (a
# collision would corrupt the exactly-one state invariant).
_sh_labels_validate() {
  local keys k
  keys="$(printf '%s' "$_SH_CONFIG_JSON" | jq -r '.labels // {} | keys[]' 2>/dev/null)" || {
    echo "smallhours: config 'labels:' is not a map of canonical -> repo label" >&2
    return 1
  }
  for k in $keys; do
    if ! _sh_is_canonical_label "$k"; then
      echo "smallhours: config labels: unknown canonical label '$k'" >&2
      return 1
    fi
    local f
    for f in "${SMALLHOURS_FIXED_LABELS[@]}"; do
      if [ "$k" = "$f" ]; then
        echo "smallhours: config labels: '$k' triggers the workflow and cannot be remapped (v1)" >&2
        return 1
      fi
    done
  done
  # Collision check across ALL axes (category labels share issues with the
  # state axis, PR markers share PRs with it).
  local resolved dupes
  resolved="$(
    for k in "${SMALLHOURS_STATE_LABELS[@]}" "${SMALLHOURS_PR_LABELS[@]}" \
             "${SMALLHOURS_CATEGORY_LABELS[@]}"; do
      _sh_label_raw "$k"
    done
  )"
  dupes="$(printf '%s\n' "$resolved" | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    echo "smallhours: config labels: two canonical labels resolve to the same string: $dupes" >&2
    return 1
  fi
  return 0
}

# Mapping lookup without canonical-name validation (internal).
_sh_label_raw() { # canonical
  local v; v="$(printf '%s' "$_SH_CONFIG_JSON" | jq -r ".labels[\"$1\"] // empty")"
  [ -n "$v" ] && printf '%s\n' "$v" || printf '%s\n' "$1"
}

# THE resolver: canonical label name -> the string that actually appears on
# this repo's issues/PRs. No script may reference a repo label except through
# this (or via state.sh, which resolves internally). Unknown canonical names
# are a programming error — die loudly.
label_for() { # canonical
  config_load || return 1
  if ! _sh_is_canonical_label "$1"; then
    echo "smallhours: label_for: not a canonical label: '$1'" >&2
    return 1
  fi
  _sh_label_raw "$1"
}

# The full state axis as it appears on this repo, one label per line.
state_labels_resolved() {
  config_load || return 1
  local l
  for l in "${SMALLHOURS_STATE_LABELS[@]}"; do _sh_label_raw "$l"; done
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

config_max_concurrent() {
  local v; v="$(_sh_get '.max_concurrent')"
  [ -n "$v" ] && echo "$v" || echo "$_SH_DEFAULT_MAX_CONCURRENT"
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
