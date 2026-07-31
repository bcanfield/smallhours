#!/usr/bin/env bash
# test-sandbox-config.sh — the consumer `sandbox:` seam and the verify-gate
# config keys. Pure logic only (no CLI, no network, no sudo).
#
# The load-bearing property is NEGATIVE: a consumer must be able to widen the
# hardened profile's lists and must NOT be able to flip its booleans. Every
# `allowUnsandboxedCommands` / `filesystem.disabled` case below is there because
# a passing render of one of those would silently dissolve the boundary ADR 0001
# rests on — and it would look exactly like success.
#
# The whitelist is also asserted to FAIL CLOSED: a key nobody has thought about
# is dropped, not merged. That is what makes an upstream Claude Code addition
# inert here until it is considered.
# Run: tests/test-sandbox-config.sh
set -uo pipefail
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR="$_dir/../scripts/lib/claude-run.sh"
CFG="$_dir/../scripts/lib/config.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/smallhours-sandbox.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
case_banner() { echo "case: $1"; }

# Render the managed settings against a given config file.
render() { # config-file
  ( SMALLHOURS_CONFIG="$1"; unset GITHUB_WORKSPACE
    . "$CR" 2>/dev/null || exit 90
    claude_run_render_settings 2>/dev/null )
}
# Read a config getter against a given config file.
cfg() { # config-file getter args...
  local f="$1"; shift
  ( SMALLHOURS_CONFIG="$f"; unset GITHUB_WORKSPACE
    . "$CFG" 2>/dev/null || exit 90
    "$@" 2>/dev/null )
}
# Stderr only, for the warning assertions.
cfg_warn() { # config-file getter
  local f="$1"; shift
  ( SMALLHOURS_CONFIG="$f"; unset GITHUB_WORKSPACE
    . "$CFG" 2>/dev/null || exit 90
    "$@" 2>&1 >/dev/null )
}

printf 'version: 1\n' > "$FIX/empty.yml"

# A consumer trying to have it every way at once: legitimate widenings next to
# three separate attempts on the hardening floor.
cat > "$FIX/mixed.yml" <<'EOF'
version: 1
npm_allowed: true
egress_extra_domains: ["example.com"]
sandbox:
  filesystem:
    allowWrite: ["~/.local/share/pnpm", "~/.cache"]
    disabled: true
  excludedCommands: ["docker *"]
  allowUnsandboxedCommands: true
  enableWeakerNestedSandbox: true
  network:
    allowedDomains: ["github.com", "registry.example.org"]
    allowAllUnixSockets: true
    allowUnixSockets: ["/var/run/docker.sock"]
EOF

case_banner "no sandbox: block — the pre-existing consumer"
before="$(render "$FIX/empty.yml")"
case "$(printf '%s' "$before" | jq -r '.sandbox.filesystem // "absent"')" in
  absent) ok "renders no filesystem block at all" ;;
  *)      bad "invented a filesystem block: $(printf '%s' "$before" | jq -c .sandbox.filesystem)" ;;
esac
case "$(printf '%s' "$before" | jq -r '.sandbox.excludedCommands | length')" in
  0) ok "excludedCommands stays empty" ;;
  *) bad "excludedCommands is not empty" ;;
esac
case "$(cfg "$FIX/empty.yml" config_sandbox_json)" in
  '{}') ok "config_sandbox_json is {} when the key is absent" ;;
  *)    bad "expected {} for an absent sandbox key" ;;
esac

case_banner "the hardening floor is not consumer-settable"
after="$(render "$FIX/mixed.yml")"
case "$(printf '%s' "$after" | jq -r '.sandbox.allowUnsandboxedCommands')" in
  false) ok "allowUnsandboxedCommands stays false" ;;
  *)     bad "consumer flipped allowUnsandboxedCommands — the escape hatch is open" ;;
esac
case "$(printf '%s' "$after" | jq -r '.sandbox.enableWeakerNestedSandbox')" in
  false) ok "enableWeakerNestedSandbox stays false" ;;
  *)     bad "consumer weakened the nested sandbox" ;;
esac
case "$(printf '%s' "$after" | jq -r '.sandbox.filesystem.disabled // "absent"')" in
  absent) ok "filesystem.disabled never reaches the settings" ;;
  *)      bad "consumer disabled filesystem isolation" ;;
esac
case "$(printf '%s' "$after" | jq -r '.sandbox.network.allowAllUnixSockets')" in
  false) ok "allowAllUnixSockets stays false" ;;
  *)     bad "consumer opened all Unix sockets" ;;
esac
case "$(printf '%s' "$after" | jq -r '.sandbox.network.allowUnixSockets | length')" in
  0) ok "allowUnixSockets stays empty (docker.sock is a host escape)" ;;
  *) bad "consumer added a Unix socket: $(printf '%s' "$after" | jq -c '.sandbox.network.allowUnixSockets')" ;;
esac
case "$(printf '%s' "$after" | jq -r '.sandbox.enabled, .sandbox.failIfUnavailable, .sandbox.allowManagedDomainsOnly' | tr '\n' ',')" in
  'true,true,true,') ok "enabled/failIfUnavailable/allowManagedDomainsOnly all still true" ;;
  *)                 bad "a core sandbox boolean moved" ;;
esac

case_banner "legitimate widenings do apply"
case "$(printf '%s' "$after" | jq -r '.sandbox.filesystem.allowWrite | sort | join(",")')" in
  '~/.cache,~/.local/share/pnpm') ok "allowWrite carries both store paths" ;;
  *) bad "allowWrite wrong: $(printf '%s' "$after" | jq -c '.sandbox.filesystem.allowWrite')" ;;
esac
case "$(printf '%s' "$after" | jq -r '.sandbox.excludedCommands | join(",")')" in
  'docker *') ok "excludedCommands carries the consumer entry" ;;
  *) bad "excludedCommands wrong: $(printf '%s' "$after" | jq -c '.sandbox.excludedCommands')" ;;
esac

case_banner "allowedDomains merges rather than replaces"
doms="$(printf '%s' "$after" | jq -r '.sandbox.network.allowedDomains | join(",")')"
for d in 'api.anthropic.com' '*.github.com' 'example.com' 'registry.example.org' 'registry.npmjs.org'; do
  case "$doms" in
    *"$d"*) ok "keeps $d" ;;
    *)      bad "lost $d — a consumer list replaced the base allowlist: $doms" ;;
  esac
done
case "$(printf '%s' "$after" | jq -r '[.sandbox.network.allowedDomains[] | select(. == "github.com")] | length')" in
  1) ok "github.com appears once (deduped against the base)" ;;
  *) bad "duplicate domain entries" ;;
esac

case_banner "an unknown key fails closed"
cat > "$FIX/unknown.yml" <<'EOF'
version: 1
sandbox:
  someFutureKey: ["surprise"]
  filesystem:
    allowWrite: ["/tmp/ok"]
EOF
u="$(cfg "$FIX/unknown.yml" config_sandbox_json)"
case "$u" in
  *someFutureKey*) bad "an unwhitelisted key was merged: $u" ;;
  *)               ok "unwhitelisted key dropped" ;;
esac
case "$u" in
  */tmp/ok*) ok "the whitelisted sibling still applies" ;;
  *)         bad "dropped a valid key alongside the unknown one: $u" ;;
esac

case_banner "dropped keys are named on stderr, not swallowed"
w="$(cfg_warn "$FIX/mixed.yml" config_sandbox_json)"
for k in 'allowUnsandboxedCommands' 'filesystem.disabled' 'network.allowAllUnixSockets'; do
  case "$w" in
    *"$k"*) ok "warns about $k" ;;
    *)      bad "silently dropped $k: $w" ;;
  esac
done
case "$(cfg_warn "$FIX/empty.yml" config_sandbox_json)" in
  '') ok "no warning when there is nothing to warn about" ;;
  *)  bad "warned on an absent sandbox key" ;;
esac

case_banner "verify-gate config keys"
case "$(cfg "$FIX/empty.yml" config_verify)" in
  '') ok "verify is empty by default (no gate — today's behaviour)" ;;
  *)  bad "invented a default verify command" ;;
esac
case "$(cfg "$FIX/empty.yml" config_verify_reentries)" in
  2) ok "verify_reentries defaults to 2" ;;
  *) bad "wrong default for verify_reentries" ;;
esac
cat > "$FIX/verify.yml" <<'EOF'
version: 1
verify: pnpm verify && echo done
verify_reentries: 0
EOF
case "$(cfg "$FIX/verify.yml" config_verify)" in
  'pnpm verify && echo done') ok "verify passes a compound command through verbatim" ;;
  *) bad "mangled the verify command: $(cfg "$FIX/verify.yml" config_verify)" ;;
esac
case "$(cfg "$FIX/verify.yml" config_verify_reentries)" in
  0) ok "verify_reentries: 0 is honoured (gate runs, never re-enters)" ;;
  *) bad "0 did not survive — a falsy-vs-absent confusion" ;;
esac
printf 'version: 1\nverify_reentries: "lots"\n' > "$FIX/bogus.yml"
case "$(cfg "$FIX/bogus.yml" config_verify_reentries)" in
  2) ok "a non-numeric verify_reentries falls back to the default" ;;
  *) bad "non-numeric reentries leaked into a loop bound" ;;
esac

case_banner "max_turns for the re-entry stage"
case "$(cfg "$FIX/empty.yml" config_max_turns verify_reentry)" in
  30) ok "verify_reentry defaults to 30 turns, not implement's 100" ;;
  *)  bad "wrong verify_reentry turn cap" ;;
esac
printf 'version: 1\nmax_turns:\n  verify_reentry: 5\n' > "$FIX/turns.yml"
case "$(cfg "$FIX/turns.yml" config_max_turns verify_reentry)" in
  5) ok "verify_reentry turn cap is consumer-tunable" ;;
  *) bad "consumer max_turns.verify_reentry ignored" ;;
esac

echo
echo "test-sandbox-config: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
