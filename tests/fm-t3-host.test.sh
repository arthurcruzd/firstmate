#!/usr/bin/env bash
# tests/fm-t3-host.test.sh - bin/fm-t3-host.sh and bin/fm-t3-host-lib.sh: the
# relay-ownership predicate the Stop auto-arm, turn-end guard, and protocol
# renderer stand aside for, the protocol block a relay-owned home renders,
# launch/adopt of a primary thread against tests/t3-fake-server.mjs, and the
# relay hosting the away daemon in away or quiet mode, on a home that opted out
# of the supervision host (tests/fm-t3-supervision-host.test.sh covers the
# relay running it).
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
  printf 'pid=%s\nstarted=%s\n' "$relay" "$(ps -o lstart= -p "$relay" | sed 's/^ *//; s/ *$//')" > "$state/.t3-relay"
  owns "$state" || fail "a relay record written in the older ps lstart spelling must still own the home"
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

# until <seconds> <command...>: poll every 0.2s until the command succeeds.
until_true() {
  local n=$(( $1 * 5 ))
  shift
  while [ "$n" -gt 0 ]; do
    "$@" 2>/dev/null && return 0
    sleep 0.2
    n=$((n - 1))
  done
  return 1
}

starts_arm_at_least() {  # <log> <n>
  local c
  c=$(grep -c '^arm ' "$1" 2>/dev/null)
  [ "${c:-0}" -ge "$2" ]
}

starts_at_least() {  # <log> <n>
  local c
  c=$(grep -c '^start ' "$1" 2>/dev/null)
  [ "${c:-0}" -ge "$2" ]
}

# In away or quiet mode the relay runs the away daemon itself, aimed at the
# recorded thread, because T3 can end the session whose background job would
# otherwise host it: it restarts the daemon while the flag stands, never starts
# one under an away-mode launch or beside a live daemon, and stops it once the
# flag clears or the relay itself is stopped.
test_relay_hosts_away_daemon() {
  local home="$TMP_ROOT/hosted" entry log relay lockholder pid
  mkdir -p "$home/state" "$home/config"
  # The plain relay: tests/fm-t3-supervision-host.test.sh covers the host.
  : > "$home/config/supervision-host-off"
  log="$home/daemon.log"
  entry="$TMP_ROOT/fake-daemon.sh"
  cat > "$entry" <<'SH'
#!/usr/bin/env bash
printf 'start %s home=%s backend=%s target=%s prepared=%s harness=%s\n' "$$" "$FM_HOME" \
  "${FM_SUPERVISOR_BACKEND:-}" "${FM_SUPERVISOR_TARGET:-}" "${FM_AFK_STATE_PREPARED:-}" \
  "${FM_DAEMON_PRIMARY_HARNESS:-}" >> "$FAKE_DAEMON_LOG"
trap 'printf "term %s\n" "$$" >> "$FAKE_DAEMON_LOG"; exit 0' TERM
while :; do sleep 0.1; done
SH
  chmod +x "$entry"
  printf 'thread=mcp:primary\n' > "$home/state/.t3-host"
  printf 'quiet\n%s\n' "$(date +%s)" > "$home/state/.afk"
  FM_HOME="$home" FAKE_DAEMON_LOG="$log" FM_T3_RELAY_DAEMON_ENTRY="$entry" \
    FM_T3_RELAY_IDLE_POLL=1 FM_T3_RELAY_MODE_POLL=1 "$ROOT/bin/fm-t3-host.sh" relay > "$home/relay.out" 2>&1 &
  relay=$!
  FAKE_PIDS+=("$relay")
  until_true 10 starts_at_least "$log" 1 || fail "the relay did not start the away daemon while state/.afk stood: $(cat "$home/relay.out")"
  assert_contains "$(head -1 "$log")" "home=$home backend=t3code target=mcp:primary prepared=1 harness=claude" \
    "the hosted daemon must be aimed at the recorded thread with launcher-prepared state"
  pid=$(awk 'NR==1 {print $2}' "$log")
  kill -KILL "$pid" 2>/dev/null
  until_true 10 starts_at_least "$log" 2 || fail "the relay did not restart a daemon that died while the flag stood"
  # An away-mode launch or stop in progress, or a daemon another owner runs,
  # keeps the relay from starting one.
  sleep 60 &
  lockholder=$!
  FAKE_PIDS+=("$lockholder")
  mkdir -p "$home/state/.afk-launch.lock"
  printf '%s' "$lockholder" > "$home/state/.afk-launch.lock/pid"
  pid=$(awk '/^start / {p=$2} END {print p}' "$log")
  kill -KILL "$pid" 2>/dev/null
  sleep 3
  starts_at_least "$log" 3 && fail "the relay started a daemon under a live away-mode launch lock"
  rm -rf "$home/state/.afk-launch.lock"
  until_true 10 starts_at_least "$log" 3 || fail "the relay did not resume hosting once the launch lock cleared"
  pid=$(awk '/^start / {p=$2} END {print p}' "$log")
  rm -f "$home/state/.afk"
  until_true 10 grep -q "^term $pid$" "$log" || fail "the relay did not stop its daemon when state/.afk cleared"
  sleep 2
  starts_at_least "$log" 4 && fail "the relay restarted the daemon after the flag cleared"
  kill -0 "$relay" 2>/dev/null || fail "the relay must keep running in attended mode after the flag clears"
  printf 'away\n%s\n' "$(date +%s)" > "$home/state/.afk"
  until_true 10 starts_at_least "$log" 4 || fail "the relay did not host the daemon again on a new away entry"
  pid=$(awk '/^start / {p=$2} END {print p}' "$log")
  kill -TERM "$relay"
  wait "$relay" 2>/dev/null
  until_true 5 grep -q "^term $pid$" "$log" || fail "stopping the relay did not stop the daemon it hosts"
  [ ! -e "$home/state/.t3-relay" ] || fail "a stopped relay must remove its record"
  pass "fm-t3-host.sh relay: hosts the away daemon while state/.afk stands, restarts it, defers to a launch in progress, and stops it with the flag or the relay"
}

# An attended wake reaches the recorded thread under a request id naming the
# relay and the closed cycle. Entering away or quiet mode while the relay waits
# on a watcher cycle ends that cycle at once and delivers nothing: the watcher
# queued the wake durably, and the daemon the relay then runs drains it, so no
# routine wake reaches the thread after the mode began.
test_relay_hands_open_watcher_cycle_to_daemon() {
  local home="$TMP_ROOT/handoff" arm entry log relay sends
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host-off"
  log="$home/events.log"
  [ -n "$T3_FAKE_PID" ] || t3_fake_start "$TMP_ROOT/server" T3CODE_TELEMETRY_ENABLED=false
  t3_fake_case "$TMP_ROOT/case-handoff"
  t3_fake_set 'w.threads = { "mcp:primary": { threadId: "mcp:primary", projectId: "p", status: "completed", activeRunId: null, archived: false, worktreePath: null, pendingRequestCount: 0, items: [], runs: [] } }'
  t3_fake_credential "$home/config/t3code-token"
  arm="$TMP_ROOT/fake-arm.sh"
  # The first cycle closes on a wake at once (attended delivery); later cycles
  # stay open until stopped, then report the wake that closed them.
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf 'arm %s\n' "$$" >> "$FAKE_LOG"
if [ "$(grep -c '^arm ' "$FAKE_LOG")" -eq 1 ]; then
  printf 'signal: %s/state/early.status\n' "$FM_HOME"
  exit 0
fi
trap 'printf "arm-term %s\n" "$$" >> "$FAKE_LOG"; printf "signal: %s/state/late.status\n" "$FM_HOME"; exit 0' TERM
while :; do sleep 0.1; done
SH
  entry="$TMP_ROOT/fake-daemon-2.sh"
  cat > "$entry" <<'SH'
#!/usr/bin/env bash
printf 'start %s\n' "$$" >> "$FAKE_LOG"
trap 'exit 0' TERM
while :; do sleep 0.1; done
SH
  chmod +x "$arm" "$entry"
  printf 'thread=mcp:primary\n' > "$home/state/.t3-host"
  printf 'window=fm-w\nbackend=t3code\n' > "$home/state/w.meta"
  FM_HOME="$home" FAKE_LOG="$log" FM_T3_RELAY_ARM_ENTRY="$arm" FM_T3_RELAY_DAEMON_ENTRY="$entry" \
    FM_T3_RELAY_IDLE_POLL=1 FM_T3_RELAY_MODE_POLL=1 "$ROOT/bin/fm-t3-host.sh" relay > "$home/relay.out" 2>&1 &
  relay=$!
  FAKE_PIDS+=("$relay")
  until_true 15 grep -q 'delivered fm-t3-relay-' "$home/relay.out" || fail "the relay did not deliver an attended wake: $(cat "$home/relay.out")"
  sends=$(t3_fake_calls t3_thread_send)
  assert_contains "$sends" '"threadId":"mcp:primary"' "the attended wake goes to the recorded thread"
  assert_contains "$sends" "Firstmate wake from the T3 wake relay:" "the attended wake carries the relay's header"
  assert_contains "$sends" "early.status" "the attended wake carries the watcher's reason line"
  assert_contains "$sends" "\"clientRequestId\":\"fm-t3-relay-$relay-$(awk '/^arm / {print $2; exit}' "$log")-1\"" \
    "the delivery request id names the relay and the cycle that closed"
  until_true 10 starts_arm_at_least "$log" 2 || fail "the relay did not open a second watcher cycle after delivering"
  printf 'quiet\n%s\n' "$(date +%s)" > "$home/state/.afk"
  until_true 10 grep -q '^arm-term ' "$log" || fail "entering quiet mode did not end the relay's open watcher cycle"
  until_true 10 starts_at_least "$log" 1 || fail "the relay did not run the daemon after handing over the watcher"
  assert_not_contains "$(t3_fake_calls t3_thread_send)" "late.status" "a wake closing after the mode began must not be delivered"
  assert_not_contains "$(cat "$home/relay.out")" "delivery of" "a wake closing after the mode began must not be attempted"
  kill -TERM "$relay"
  wait "$relay" 2>/dev/null
  pass "fm-t3-host.sh relay: delivers an attended wake to the recorded thread, and entering away or quiet mode mid-cycle hands the watcher to the daemon without posting the closing wake"
}

test_relay_ownership_predicate
test_protocol_renders_relay_mode
test_launch_and_adopt
test_relay_hosts_away_daemon
test_relay_hands_open_watcher_cycle_to_daemon
