#!/usr/bin/env bash
# Behavior tests for the supervision host run by the T3 wake relay
# (bin/fm-t3-host.sh relay, bin/fm-supervision-host.sh RELAY MODE): a Claude
# primary that runs as a T3 Code thread.
#
# Each case runs the real relay against tests/t3-fake-server.mjs, and the real
# host, arm, watcher, wake grant, drain, outcome store, lease, and dialog-mirror
# scripts in a fixture home. The primary's session is a fake harness (a bash
# symlink named "claude") that holds the home's session lock until the case
# unloads it, as T3 unloads an idle session. The engine is a stub named by
# FM_SUPERVISION_ENGINE_CLAUDE_BIN that does what a branch turn does through the
# same scripts. A real status append drives each wake through the real watcher.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }
command -v perl >/dev/null 2>&1 || { printf 'skip: perl absent\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v curl >/dev/null 2>&1 || { printf 'skip: curl absent\n'; exit 0; }

RELAY="$ROOT/bin/fm-t3-host.sh"
HOST="$ROOT/bin/fm-supervision-host.sh"

TMP_ROOT=$(fm_test_tmproot fm-t3-supervision-host)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# The stub engine: drain, claim the task's lease, report, acknowledge, and
# release, by $FM_HOME/stub-mode: handle reports routine, captain reports
# verdict captain.
STUB="$TMP_ROOT/engine-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -u
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
mode=$(cat "$FM_HOME/stub-mode" 2>/dev/null || echo handle)
n=$(( $(ls "$FM_HOME"/engine-call.* 2>/dev/null | wc -l) + 1 ))
{
  printf 'mode=%s\nactor=%s\nholder=%s\nprimary=%s\nturn=%s\n' "$mode" "${FM_SUPERVISION_ACTOR:-}" \
    "${FM_LEASE_HOLDER_PID:-}" "${FM_SUPERVISION_PRIMARY_HARNESS:-}" "${FM_BRANCH_REPORT_TURN:-}"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$FM_HOME/engine-call.$n"
drain=$("$FM_REPO/bin/fm-wake-drain.sh" 2>&1)
ack=$(printf '%s\n' "$drain" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
task=$(sed -n 's/^tasks=//p' "$STATE/.supervision-host-turn" | awk '{ print $1 }')
[ -n "$task" ] || task=fleet
"$FM_REPO/bin/fm-lease.sh" claim "$task" >> "$FM_HOME/engine-lease.log" 2>&1
if [ "$mode" = captain ]; then
  "$FM_REPO/bin/fm-branch-report.sh" --task "$task" --verdict captain \
    --summary "The demo fix is ready for review" >> "$FM_HOME/engine-report.log" 2>&1
else
  "$FM_REPO/bin/fm-branch-report.sh" --task "$task" --verdict routine \
    --summary "stub handled $task" >> "$FM_HOME/engine-report.log" 2>&1
fi
# shellcheck disable=SC2086 # the printed acknowledgement arguments
[ -z "$ack" ] || "$FM_REPO/bin/fm-wake-drain.sh" $ack >> "$FM_HOME/engine-ack.log" 2>&1
"$FM_REPO/bin/fm-lease.sh" release "$task" >> "$FM_HOME/engine-lease.log" 2>&1
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":%s,' "$(awk -v n="$n" 'BEGIN { print n * 0.25 }')"
printf '"usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens":20},"session_id":"stub"}\n'
SH
chmod +x "$STUB"

export FM_REPO="$ROOT"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$STUB"
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export FM_SUPERVISION_ENGINE_GRACE=1 FM_ARM_CONFIRM_TIMEOUT=30
export FM_T3_RELAY_IDLE_POLL=1 FM_T3_RELAY_MODE_POLL=1
unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN FM_LEASE_HOLDER_PID PI_CODING_AGENT FM_SUPERVISION_HOST_T3_RELAY_PID

# A git checkout that passes the primary-scope check, so the dialog-mirror
# writer runs; its bin is this repo's bin.
MIRROR_ROOT="$TMP_ROOT/mirror-root"
mkdir -p "$MIRROR_ROOT"
git init -q "$MIRROR_ROOT"
: > "$MIRROR_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$MIRROR_ROOT/bin"

HOMES_FILE="$TMP_ROOT/homes"
stop_home() {  # <home>
  local home=$1 pid i=0
  pid=$(sed -n 's/^pid=//p' "$home/state/.t3-relay" 2>/dev/null)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 100 ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host" 2>/dev/null)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  while IFS= read -r pid; do
    kill -TERM "$pid" 2>/dev/null || true
  done < <(cat "$home/session-pids" 2>/dev/null)
}
suite_cleanup() {
  local home
  while IFS= read -r home; do
    [ -n "$home" ] && stop_home "$home"
  done < <(cat "$HOMES_FILE" 2>/dev/null)
  t3_fake_stop
  fm_test_cleanup
}
trap suite_cleanup EXIT

t3_fake_start "$TMP_ROOT/server" T3CODE_TELEMETRY_ENABLED=false

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/fakebin"
  # An unreachable backend: the watcher reads no endpoint as dead, so the only
  # wakes are the status appends each case makes.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/tmux"
  chmod +x "$home/fakebin/tmux"
  make_fake_crew_state "$home/fakebin" >/dev/null
  printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$home/state/demo.meta"
  printf 'thread=mcp:primary\n' > "$home/state/.t3-host"
  echo handle > "$home/stub-mode"
  printf '%s\n' "$home" >> "$HOMES_FILE"
  printf '%s\n' "$home"
}

# Point the fake T3 server at <home>'s own world, with the primary's thread
# and a credential for it. Runs in this shell: it sets the request log path.
use_t3() {  # <home>
  t3_fake_case "$1/t3case"
  t3_fake_set 'w.threads = { "mcp:primary": { threadId: "mcp:primary", projectId: "p", status: "completed", activeRunId: null, archived: false, worktreePath: null, pendingRequestCount: 0, items: [], runs: [] } }'
  t3_fake_credential "$1/config/t3code-token"
}

home_env() {  # <home> <command...>
  local home=$1
  shift
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" "$@"
}

# The primary's session: takes the session lock as session start does,
# mirrors one captain prompt through the real Claude writer, and stays alive
# until the case unloads it.
open_session() {  # <home> [prompt]
  local home=$1 prompt=${2:-watch the fleet for me} i=0
  rm -f "$home/session.ready"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p%s","prompt":"%s"}' "$RANDOM" "$prompt" > "$home/session.seed"
  home_env "$home" env MIRROR_ROOT="$MIRROR_ROOT" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "$$" >> "$FM_HOME/session-pids"
    FM_ROOT_OVERRIDE="$MIRROR_ROOT" "$MIRROR_ROOT/bin/fm-host-mirror.sh" hook claude < "$FM_HOME/session.seed"
    : > "$FM_HOME/session.ready"
    while :; do sleep 1; done
  ' 2>> "$home/session.err" &
  while [ "$i" -lt 100 ] && [ ! -e "$home/session.ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$home/session.ready" ] || fail "fixture: the primary session did not start: $(cat "$home/session.err")"
}
session_pid() { sed -n '1p' "$1/state/.lock"; }
unload_session() {  # <home>: T3 releases the idle session's process
  local pid
  pid=$(session_pid "$1")
  kill -TERM "$pid" 2>/dev/null
  wait_until 50 eval '! kill -0 "$pid" 2>/dev/null' || fail "fixture: the session did not end"
}

start_relay() {  # <home>
  home_env "$1" bash -c 'exec "$0" relay' "$RELAY" > "$1/relay.out" 2>&1 &
}

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
watcher_live() {
  local pid
  pid=$(cat "$1/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
host_pid() { awk -F '\t' '$1 == "host" { print $2; exit }' "$1/state/.supervision-host" 2>/dev/null; }
host_live() { local p; p=$(host_pid "$1"); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
count_re() { local n; n=$(grep -c -E -- "$1" "$2" 2>/dev/null); printf '%s\n' "${n:-0}"; }
handled_at_least() { [ "$(count_re '	handled	' "$1/state/.supervision-host.log")" -ge "$2" ]; }
sends() { t3_fake_calls t3_thread_send; }
send_count() { local n; n=$(sends | grep -c .); printf '%s\n' "${n:-0}"; }
sends_at_least() { [ "$(send_count)" -ge "$1" ]; }
append_status() {  # <home> <text> [verb] [key]
  printf '%s%s [at=%s]: %s\n' "${3:-working}" "${4:+ [key=$4]}" "$(date +%s)" "$2" >> "$1/state/demo.status"
}
main_drain() {  # <home>: main's drain from its session; sets MAIN_ACK
  local out
  out=$(home_env "$1" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  MAIN_ACK=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  printf '%s\n' "$out"
}
main_ack() {  # <home>
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || home_env "$1" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK
}
mirrored_captain() {  # <home>
  local n
  n=$(grep -c '"tag":"captain"' "$1/state/.host-mirror.jsonl" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}

# A routine wake is handled on the engine outside the thread, with no thread
# message and nothing for main to acknowledge; the session lock stays main's.
test_routine_wake_is_handled_without_a_thread_message() {
  local home lock host
  home=$(make_home routine)
  use_t3 "$home"
  open_session "$home"
  lock=$(cat "$home/state/.lock")
  start_relay "$home"
  wait_until 200 watcher_live "$home" || fail "routine: the relay's host never armed a watcher: $(cat "$home/relay.out")"
  host=$(host_pid "$home")
  [ -n "$host" ] || fail "routine: the relay did not run the supervision host: $(cat "$home/relay.out")"
  append_status "$home" 'step one'
  wait_until 300 handled_at_least "$home" 1 \
    || fail "routine: the wake was not handled on the engine: $(cat "$home/relay.out"; cat "$home/state/.supervision-host.log")"
  sleep 3
  [ "$(send_count)" -eq 0 ] || fail "routine: a routine wake reached the thread: $(sends)"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "routine: the engine's acknowledgement did not consume the wake"
  assert_grep '"verdict":"routine"' "$home/state/branch-outcomes.jsonl" "routine: the report did not reach the outcome store"
  assert_grep 'actor=branch' "$home/engine-call.1" "routine: the engine must run as the branch actor"
  assert_grep "holder=$lock" "$home/engine-call.1" "routine: the engine's leases must name main's session-lock holder"
  [ "$(cat "$home/state/.lock")" = "$lock" ] || fail "routine: the relay or host changed main's session lock"
  [ "$(host_pid "$home")" = "$host" ] || fail "routine: the host exited for a routine wake"
  watcher_live "$home" || fail "routine: no watcher after the handled wake"
  pass "relay host: a routine wake is handled on the engine with no thread message, and main's session lock is untouched"
  stop_home "$home"
}

# A captain outcome reaches the thread as one ordinary message carrying its
# summary, never a doorbell line; the host keeps supervising, main's drain
# presents the outcome until main acknowledges it, and the message is not
# mirrored as the captain's words when T3 submits it.
test_captain_outcome_is_one_ordinary_message() {
  local home host text before
  home=$(make_home captain)
  use_t3 "$home"
  echo captain > "$home/stub-mode"
  open_session "$home"
  start_relay "$home"
  wait_until 200 watcher_live "$home" || fail "captain: the relay's host never armed a watcher: $(cat "$home/relay.out")"
  host=$(host_pid "$home")
  append_status "$home" 'ready for review'
  wait_until 300 sends_at_least 1 \
    || fail "captain: no message reached the thread: $(cat "$home/relay.out" "$home/state/.supervision-host.log" "$home/engine-report.log" "$home/state/.supervision-host-receipts" 2>&1)"
  sleep 3
  [ "$(send_count)" -eq 1 ] || fail "captain: expected exactly one thread message: $(sends)"
  text=$(sends)
  assert_contains "$text" '"threadId":"mcp:primary"' "captain: the message must go to the recorded thread"
  assert_contains "$text" 'Firstmate supervision outcome from the T3 wake relay:' "captain: the message must say what it is"
  assert_contains "$text" '- demo: The demo fix is ready for review' "captain: the message must carry the outcome's summary"
  assert_contains "$text" 'BRANCH OUTCOMES' "captain: the message must send main to its drain"
  assert_not_contains "$text" 'operational input waiting' "captain: no doorbell line may reach the thread"
  assert_not_contains "$text" 'signal:' "captain: the handled close must not reach the thread as a wake"
  [ "$(host_pid "$home")" = "$host" ] || fail "captain: the host exited to deliver a captain outcome"
  watcher_live "$home" || fail "captain: no watcher after the outcome"
  [ -z "$(ls "$home/state/.t3-relay-outbox" 2>/dev/null)" ] || fail "captain: the delivered outbox entry was not removed"
  assert_contains "$(main_drain "$home")" ' ago] demo: The demo fix is ready for review' "captain: main's drain must present the outcome"
  assert_contains "$(main_drain "$home")" 'mark-processed --through 1' "captain: an unacknowledged outcome must be presented again"
  home_env "$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 >/dev/null || fail "captain: main's acknowledgement was refused"
  assert_not_contains "$(main_drain "$home")" 'BRANCH OUTCOMES (captain' "captain: an acknowledged outcome must not be presented again"
  # T3 submits the message as a user prompt: the Claude writer drops it.
  before=$(mirrored_captain "$home")
  t3_fake_calls t3_thread_send | head -1 | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s);process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",prompt_id:"relay",prompt:a.message??a.text??a.content??""}))})' \
    > "$home/relay-prompt.json"
  assert_grep 'Firstmate supervision outcome' "$home/relay-prompt.json" "fixture: could not rebuild the relay's prompt"
  home_env "$home" env MIRROR_ROOT="$MIRROR_ROOT" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    FM_ROOT_OVERRIDE="$MIRROR_ROOT" "$MIRROR_ROOT/bin/fm-host-mirror.sh" hook claude < "$FM_HOME/relay-prompt.json"
    printf "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"typed\",\"prompt\":\"and keep it small\"}" \
      | FM_ROOT_OVERRIDE="$MIRROR_ROOT" "$MIRROR_ROOT/bin/fm-host-mirror.sh" hook claude'
  [ "$(mirrored_captain "$home")" -eq $((before + 1)) ] \
    || fail "captain: the mirror must drop the relay's message and keep the captain's own: $(cat "$home/state/.host-mirror.jsonl")"
  assert_no_grep 'Firstmate supervision outcome' "$home/state/.host-mirror.jsonl" "captain: the relay's message was mirrored as the captain's words"
  pass "relay host: a captain outcome reaches the thread as one ordinary message with its summary, and the mirror never takes it for the captain"
  stop_home "$home"
}

# A main-only close (a decision) reaches the thread as an ordinary wake while
# the host keeps supervising on the closed arm's handling successor: no
# take-over, so main's later acknowledgement resurfaces nothing, and later
# routine wakes stay off the thread.
test_main_only_close_keeps_the_host_parked_and_resurfaces_nothing() {
  local home host
  home=$(make_home main-only)
  use_t3 "$home"
  open_session "$home"
  start_relay "$home"
  wait_until 200 watcher_live "$home" || fail "main-only: the relay's host never armed a watcher: $(cat "$home/relay.out")"
  host=$(host_pid "$home")
  append_status "$home" 'which export format?' needs-decision format
  wait_until 300 sends_at_least 1 || fail "main-only: the decision did not reach the thread: $(cat "$home/relay.out"; cat "$home/state/.supervision-host.log")"
  assert_contains "$(sends)" 'Firstmate wake from the T3 wake relay:' "main-only: the decision must arrive as an ordinary wake"
  assert_contains "$(sends)" 'demo.status' "main-only: the wake must carry the watcher's reason line"
  [ "$(host_pid "$home")" = "$host" ] || fail "main-only: the host exited to hand main a close"
  wait_until 100 watcher_live "$home" || fail "main-only: no watcher while main handles the close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "main-only: the decision must stay queued for main"
  [ -e "$home/state/.supervision-host-left" ] && fail "main-only: the relay host left a successor for a take-over"
  # Main answers the decision, which closes it, and acknowledges the wake.
  main_drain "$home" >/dev/null
  append_status "$home" 'csv' resolved format
  main_ack "$home"
  append_status "$home" 'decision received, continuing'
  wait_until 300 handled_at_least "$home" 1 || fail "main-only: the next routine wake was not handled: $(cat "$home/state/.supervision-host.log")"
  append_status "$home" 'another question?' needs-decision scope
  wait_until 300 sends_at_least 2 || fail "main-only: the second decision did not reach the thread"
  main_drain "$home" >/dev/null
  append_status "$home" 'keep it small' resolved scope
  main_ack "$home"
  append_status "$home" 'step two'
  wait_until 300 handled_at_least "$home" 2 || fail "main-only: the second routine wake was not handled"
  sleep 4
  [ "$(send_count)" -eq 2 ] || fail "main-only: expected only the two decisions on the thread: $(sends)"
  assert_not_contains "$(sends)" 'rearm-resurface' "main-only: a recovery wake resurfaced after main acknowledged"
  [ "$(host_pid "$home")" = "$host" ] || fail "main-only: the host did not stay parked across the cycle"
  pass "relay host: a decision reaches the thread as an ordinary wake while the host stays parked, and no recovery wake resurfaces"
  stop_home "$home"
}

# T3 unloads the idle session (its lock holder ends): supervision continues and
# routine wakes stay off the thread under the remembered main-session key; a
# captain outcome while unloaded tells the reopened session to run session
# start, and the next session start opens a new engine conversation.
test_unloaded_session_keeps_supervision_off_the_thread() {
  local home host second
  home=$(make_home unloaded)
  use_t3 "$home"
  open_session "$home"
  start_relay "$home"
  wait_until 200 watcher_live "$home" || fail "unloaded: the relay's host never armed a watcher: $(cat "$home/relay.out")"
  host=$(host_pid "$home")
  append_status "$home" 'step one'
  wait_until 300 handled_at_least "$home" 1 || fail "unloaded: the first wake was not handled"
  unload_session "$home"
  append_status "$home" 'step two'
  wait_until 300 handled_at_least "$home" 2 \
    || fail "unloaded: a routine wake was not handled while the session was unloaded: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'arg=--resume' "$home/engine-call.2" "unloaded: the engine conversation must continue across the unload"
  echo captain > "$home/stub-mode"
  append_status "$home" 'ready for review'
  wait_until 300 sends_at_least 1 || fail "unloaded: the captain outcome did not reach the thread"
  sleep 2
  [ "$(send_count)" -eq 1 ] || fail "unloaded: only the captain outcome may reach the thread: $(sends)"
  assert_contains "$(sends)" 'run bin/fm-session-start.sh first' "unloaded: the message must tell the reopened session to run session start"
  [ "$(host_pid "$home")" = "$host" ] || fail "unloaded: the host did not survive the unload"
  # T3 reopens the session on that message, and session start takes the lock.
  open_session "$home" 'what did I miss?'
  echo handle > "$home/stub-mode"
  append_status "$home" 'step three'
  wait_until 300 handled_at_least "$home" 4 || fail "unloaded: the wake after the reopen was not handled: $(cat "$home/state/.supervision-host.log")"
  second="$home/engine-call.$(find "$home" -maxdepth 1 -name 'engine-call.*' | sed 's/.*\.//' | sort -n | tail -1)"
  assert_grep 'arg=--session-id' "$second" "unloaded: a new main session must start a new engine conversation"
  [ "$(send_count)" -eq 1 ] || fail "unloaded: a routine wake after the reopen reached the thread: $(sends)"
  pass "relay host: an unloaded session keeps supervision and routine wakes off the thread, and the reopen starts a new engine conversation"
  stop_home "$home"
}

# One supervisor per home: a host whose relay does not own the home stands
# down before activation and leaves the owner's processes alone; a closed
# entry the relay has not sent survives a relay restart and is sent once; and
# the session lock's absence is never ownership.
test_ownership_and_outbox_durability() {
  local home out rp watcher
  home=$(make_home ownership)
  use_t3 "$home"
  open_session "$home"
  start_relay "$home"
  wait_until 200 watcher_live "$home" || fail "ownership: the relay's host never armed a watcher: $(cat "$home/relay.out")"
  watcher=$(cat "$home/state/.watch.lock/pid")
  out=$(home_env "$home" env FM_SUPERVISION_HOST_T3_RELAY_PID=$$ FM_SUPERVISION_HOST_PRIMARY=claude "$HOST" park 2>&1)
  assert_contains "$out" 'supervision-host stood down: this session does not own supervision' \
    "ownership: a host launched for another relay must stand down"
  [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "ownership: the refused host touched the owner's watcher"
  out=$(home_env "$home" env FM_SUPERVISION_HOST_PRIMARY=claude "$HOST" park 2>&1)
  assert_contains "$out" 'supervision-host stood down' "ownership: a host outside the session and without the relay must stand down"
  rp=$(sed -n 's/^pid=//p' "$home/state/.t3-relay")
  home_env "$home" bash -c 'exec "$0" relay' "$RELAY" > "$home/relay2.out" 2>&1
  assert_grep 'another live relay owns' "$home/relay2.out" "ownership: a second relay must exit while one owns the home"
  stop_home "$home"
  ! kill -0 "$rp" 2>/dev/null || fail "ownership: the relay did not stop"
  # A close the host put in the outbox before the relay stopped is sent by the
  # next relay, once, under the entry's own request id.
  mkdir -p "$home/state/.t3-relay-outbox"
  printf 'signal: %s/state/demo.status\nsupervision-host: the supervision session could not take this wake: fixture; this wake is yours\n' "$home" \
    > "$home/state/.t3-relay-outbox/1000000000-1-000001.close"
  open_session "$home"
  start_relay "$home"
  wait_until 200 sends_at_least 1 || fail "ownership: the next relay did not send the leftover entry: $(cat "$home/relay.out")"
  assert_contains "$(sends)" '"clientRequestId":"fm-t3-relay-1000000000-1-000001"' "ownership: the entry must be sent under its own request id"
  assert_contains "$(sends)" 'supervision-host: the supervision session could not take this wake' "ownership: the host's reason must reach main"
  wait_until 50 eval '[ -z "$(ls "$home/state/.t3-relay-outbox" 2>/dev/null)" ]' || fail "ownership: the sent entry was not removed"
  sleep 2
  [ "$(send_count)" -eq 1 ] || fail "ownership: the entry was sent more than once: $(sends)"
  pass "relay host: only the relay that owns the home runs its host, and an unsent close survives a relay restart"
  stop_home "$home"
}

# A home that opted out (config/supervision-host-off) keeps the plain relay:
# its watcher cycle is bin/fm-watch-arm.sh and every wake reaches the thread
# as before, and the main-session key never outlives a dead holder there.
test_opted_out_home_keeps_the_plain_relay() {
  local home arm hostseam pid key
  home=$(make_home opted-out)
  use_t3 "$home"
  : > "$home/config/supervision-host-off"
  arm="$TMP_ROOT/plain-arm.sh"
  hostseam="$TMP_ROOT/host-seam.sh"
  printf '#!/usr/bin/env bash\nprintf "arm\\n" >> "$FM_HOME/cycles"\nprintf "signal: %%s/state/demo.status\\n" "$FM_HOME"\n' > "$arm"
  printf '#!/usr/bin/env bash\nprintf "host\\n" >> "$FM_HOME/cycles"\nexit 0\n' > "$hostseam"
  chmod +x "$arm" "$hostseam"
  open_session "$home"
  home_env "$home" env FM_T3_RELAY_ARM_ENTRY="$arm" FM_T3_RELAY_HOST_ENTRY="$hostseam" \
    bash -c 'exec "$0" relay' "$RELAY" > "$home/relay.out" 2>&1 &
  wait_until 200 sends_at_least 1 || fail "opted out: the plain relay did not deliver the wake: $(cat "$home/relay.out")"
  assert_contains "$(sends)" 'Firstmate wake from the T3 wake relay:' "opted out: the wake must arrive as before"
  assert_no_grep host "$home/cycles" "opted out: the relay ran the host on a home that opted out"
  stop_home "$home"
  # No relay record: a dead holder's key is never remembered or recalled.
  home=$(make_home no-relay)
  use_t3 "$home"
  rm -f "$home/state/.t3-host"
  open_session "$home"
  key=$(bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-engine-lib.sh"; fm_supervision_host_main_key "$2"' _ "$ROOT" "$home/state")
  [ -n "$key" ] || fail "no relay: a live holder must have a main-session key"
  [ ! -e "$home/state/.supervision-host-t3-key" ] || fail "no relay: a home no relay owns must not remember its key"
  pid=$(session_pid "$home")
  unload_session "$home"
  printf '%s\t%s\n' "$pid" "$key" > "$home/state/.supervision-host-t3-key"
  bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-engine-lib.sh"; fm_supervision_host_main_key "$2"' _ "$ROOT" "$home/state" \
    && fail "no relay: a dead holder's key must not be recalled on a home no relay owns"
  pass "relay host: an opted-out home keeps the plain relay, and no home without a relay remembers a dead holder's key"
}

test_routine_wake_is_handled_without_a_thread_message
test_captain_outcome_is_one_ordinary_message
test_main_only_close_keeps_the_host_parked_and_resurfaces_nothing
test_unloaded_session_keeps_supervision_off_the_thread
test_ownership_and_outbox_durability
test_opted_out_home_keeps_the_plain_relay
