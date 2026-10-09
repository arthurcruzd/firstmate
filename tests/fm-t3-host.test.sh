#!/usr/bin/env bash
# tests/fm-t3-host.test.sh - bin/fm-t3-host.sh and bin/fm-t3-host-lib.sh: the
# relay-ownership predicate the Stop auto-arm, turn-end guard, and protocol
# renderer stand aside for, the protocol block a relay-owned home renders, and
# launch/adopt of a primary thread against tests/t3-fake-server.mjs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-t3-host-tests)
FAKE_PIDS=()
cleanup() {
  local p
  for p in "${FAKE_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT

owns() {  # <state-dir> -> 0 when a live relay owns it
  bash -c '. "$1/bin/fm-t3-host-lib.sh"; fm_t3_relay_owns_home "$2"' _ "$ROOT" "$1"
}

started_of() {  # <pid>
  bash -c '. "$1/bin/fm-t3-host-lib.sh"; fm_t3_relay_proc_started "$2"' _ "$ROOT" "$1"
}

test_relay_ownership_predicate() {
  local state="$TMP_ROOT/own/state" relay other
  mkdir -p "$state"
  owns "$state" && fail "a home with no relay record must not be relay-owned"
  bash -c 'sleep 60; :' fm-t3-host.sh relay &
  relay=$!
  FAKE_PIDS+=("$relay")
  sleep 60 &
  other=$!
  FAKE_PIDS+=("$other")
  sleep 0.2
  printf 'pid=%s\nstarted=%s\n' "$relay" "$(started_of "$relay")" > "$state/.t3-relay"
  owns "$state" || fail "a live relay process with a matching start stamp must own the home"
  printf 'pid=%s\nstarted=%s\n' "$relay" "Thu Jan  1 00:00:00 1970" > "$state/.t3-relay"
  owns "$state" && fail "a reused pid whose start stamp differs must not own the home"
  printf 'pid=%s\nstarted=%s\n' "$other" "$(started_of "$other")" > "$state/.t3-relay"
  owns "$state" && fail "a live process that is not the relay must not own the home"
  kill "$relay" 2>/dev/null
  wait "$relay" 2>/dev/null
  printf 'pid=%s\nstarted=%s\n' "$relay" "x" > "$state/.t3-relay"
  owns "$state" && fail "a dead relay must not own the home"
  printf 'pid=abc\n' > "$state/.t3-relay"
  owns "$state" && fail "a malformed record must not own the home"
  pass "fm_t3_relay_owns_home: only a live, identity-matched relay process owns the home"
}

test_protocol_renders_relay_mode() {
  local home="$TMP_ROOT/proto" relay out
  mkdir -p "$home/state" "$home/config"
  touch "$home/config/supervision-host-off"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude)
  assert_contains "$out" "Mode: Claude Stop-hook-owned supervision." "without a relay the Claude protocol renders"
  bash -c 'sleep 60; :' fm-t3-host.sh relay &
  relay=$!
  FAKE_PIDS+=("$relay")
  sleep 0.2
  printf 'pid=%s\nstarted=%s\n' "$relay" "$(started_of "$relay")" > "$home/state/.t3-relay"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude)
  assert_contains "$out" "Mode: T3 wake-relay supervision" "a relay-owned home renders the relay protocol"
  assert_not_contains "$out" "Stop-hook-owned supervision" "the Stop-hook protocol is replaced, not appended"
  assert_contains "$out" "T3 wake relay (bin/fm-t3-host.sh relay) already owns watcher continuity" "the ordinary-wake line names the relay"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line)
  assert_contains "$out" "the T3 wake relay owns watcher supervision" "the repair line names the relay"
  kill "$relay" 2>/dev/null
  pass "fm-supervision-instructions.sh: a relay-owned home renders the T3 relay protocol and repair line"
}

test_launch_and_adopt() {
  local root="$TMP_ROOT/checkout" home="$TMP_ROOT/home" out thread rc
  t3_fake_start "$TMP_ROOT/server" T3CODE_TELEMETRY_ENABLED=false
  t3_fake_case "$TMP_ROOT/case-launch"
  mkdir -p "$root/bin" "$home/config" "$home/state"
  git init -q "$root"
  printf '# fake\n' > "$root/AGENTS.md"
  git -C "$root" add AGENTS.md
  git -C "$root" -c user.name=t -c user.email=t@t commit -qm init
  printf '{"env":{"KEEP":"1"},"permissions":{"allow":[]}}\n' > "$TMP_ROOT/settings.seed"
  mkdir -p "$root/.claude"
  cp "$TMP_ROOT/settings.seed" "$root/.claude/settings.local.json"
  t3_fake_credential "$home/config/t3code-token"
  # No global excludes, so only the script's own exclusion can hide the file.
  out=$(XDG_CONFIG_HOME="$TMP_ROOT/no-xdg" GIT_CONFIG_GLOBAL=/dev/null FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    "$ROOT/bin/fm-t3-host.sh" launch --model claude-sonnet-5-5 --effort low --title "Firstmate (test)" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "launch should succeed against the fake server: $out"
  thread=$(sed -n 's/^thread=//p' "$home/state/.t3-host")
  [ -n "$thread" ] || fail "launch must record the thread in the home's state/.t3-host"
  assert_contains "$(t3_fake_calls t3_thread_launch)" '"workspaceStrategy":{"type":"root"' "the thread runs on the project root"
  assert_contains "$(t3_fake_calls t3_project_create)" "\"workspaceRoot\":\"$root\"" "the project is the code checkout, not the home"
  assert_contains "$(t3_fake_calls t3_thread_launch)" '"instanceId":"claudeAgent","model":"claude-sonnet-5-5","options":[{"id":"effort","value":"low"}]' "the model selection carries the instance, model, and effort"
  assert_contains "$(t3_fake_calls t3_thread_launch)" '"runtimeMode":"full-access"' "the primary runs at full access"
  assert_contains "$(t3_fake_calls t3_thread_organize)" "\"threadId\":\"$thread\",\"action\":\"pin\"" "launch pins the primary thread"
  assert_equals "$home" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).env.FM_HOME)' "$root/.claude/settings.local.json")" \
    "launch writes the home into the checkout's local Claude settings"
  assert_equals 1 "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).env.KEEP)' "$root/.claude/settings.local.json")" \
    "existing local settings are kept"
  assert_equals "" "$(XDG_CONFIG_HOME="$TMP_ROOT/no-xdg" GIT_CONFIG_GLOBAL=/dev/null git -C "$root" status --porcelain -- .claude/settings.local.json)" "the local settings file is git-excluded, leaving the checkout clean"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$ROOT/bin/fm-t3-host.sh" launch 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a second launch while the recorded thread lives must be refused"
  assert_contains "$out" "already runs as T3 thread $thread" "the refusal names the live primary"
  rm -f "$home/state/.t3-host"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$ROOT/bin/fm-t3-host.sh" adopt --thread "$thread" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "adopting the live thread bound to the checkout should succeed: $out"
  assert_equals "$thread" "$(sed -n 's/^thread=//p' "$home/state/.t3-host")" "adopt records the thread"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$ROOT/bin/fm-t3-host.sh" adopt --thread mcp:gone 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "adopting a thread T3 does not have must be refused"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$ROOT/bin/fm-t3-host.sh" status 2>&1)
  assert_contains "$out" "relay=none" "status reports no relay"
  pass "fm-t3-host.sh: launch runs a full-access thread on the checkout's project root and records it in the home; adopt and status read it back"
}

test_relay_ownership_predicate
test_protocol_renders_relay_mode
test_launch_and_adopt
