#!/usr/bin/env bash
# tests/fm-t3-live-e2e.test.sh - token-free live guard for the t3 runtime
# backend's transport against the real T3 server a home is signed in to.
#
# It spends no model tokens and changes nothing on the server: the capability
# gate and environment identity (status), the provider catalog the adapter
# maps claude and codex onto (capabilities), a typed thread-not-found read
# (state), and the --environment refusal. Default-on wherever node is
# installed; FM_T3_LIVE=0 or FM_LIVE=0 turns it off, and FM_T3_LIVE=1 or
# FM_LIVE=1 makes a missing credential or unreachable server a failure.
# The credential is FM_T3_LIVE_TOKEN_FILE, else this checkout's own
# config/t3-token; neither present is a clean skip.
# docs/verification/runtime-backends.md "T3 Code" records its result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_T3_LIVE node

REQUESTED=0
[ "${FM_T3_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ] && REQUESTED=1
TOKEN=${FM_T3_LIVE_TOKEN_FILE:-$ROOT/config/t3-token}
HELPER="$ROOT/bin/fm-t3-mcp.mjs"

skip_or_fail() {  # <reason>
  if [ "$REQUESTED" = 1 ]; then
    fail "FM_T3_LIVE was requested but $1"
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}

[ -f "$TOKEN" ] || skip_or_fail "no T3 credential at $TOKEN"

field() {  # <json> <key>
  node -e 'const d=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k], d); process.stdout.write(v===undefined?"":typeof v==="object"?JSON.stringify(v):String(v))' "$1" "$2"
}

status=$(node "$HELPER" status --token-file "$TOKEN" 2>/dev/null)
rc=$?
case "$rc" in
  0) ;;
  1) skip_or_fail "the T3 server named by $TOKEN is unreachable" ;;
  *) fail "T3 status refused (exit $rc): $status" ;;
esac
version=$(field "$status" serverVersion)
env_id=$(field "$status" environmentId)
[ -n "$version" ] && [ -n "$env_id" ] || fail "T3 status lacked a version or environment id: $status"

caps=$(node "$HELPER" capabilities --token-file "$TOKEN" 2>/dev/null) || fail "T3 $version: orchestrator_capabilities failed: $caps"
for instance in claudeAgent codex; do
  assert_contains "$caps" "\"providerInstanceId\":\"$instance\"" "T3 $version: catalog lacks the $instance instance the adapter maps onto"
done

missing=$(node "$HELPER" state --thread "mcp:fm-live-guard-$$-absent" --token-file "$TOKEN" 2>/dev/null) \
  || fail "T3 $version: a read of an absent thread should succeed as exists:false: $missing"
assert_equals false "$(field "$missing" exists)" "T3 $version: an absent thread must read exists:false"

node "$HELPER" status --environment "not-$env_id" --token-file "$TOKEN" >/dev/null 2>&1
expect_code 4 $? "T3 $version: --environment must refuse a different environment"

pass "t3 live transport: T3 $version environment $env_id passes the gate (telemetry=$(field "$status" telemetry))"
