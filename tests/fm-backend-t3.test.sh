#!/usr/bin/env bash
# tests/fm-backend-t3.test.sh - the experimental t3 runtime backend driven
# through Firstmate's real owners (bin/fm-spawn.sh, fm-peek.sh, fm-send.sh,
# fm-control.sh, fm-teardown.sh) against tests/t3-fake-server.mjs and a fake
# Treehouse: the spawn into a leased worktree, every P0 refusal, peek, the
# absolute-path inbox doorbell, the native interrupt, and teardown's proven
# archive before the slot returns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-t3-tests)
trap 't3_fake_stop; fm_test_cleanup' EXIT
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"
FB=$(fm_fakebin "$TMP_ROOT")

# A fake Treehouse: `get --lease` hands out $FAKE_TH_WT, and every call is
# appended to the fake server's request log, so its order against T3 calls is
# exact.
cat > "$FB/treehouse" <<'SH'
#!/usr/bin/env bash
node -e 'require("fs").appendFileSync(process.argv[1], JSON.stringify({treehouse: process.argv.slice(2)}) + "\n")' "$T3_FAKE_LOG" "$@"
case "${1:-}" in
  get) printf '%s\n' "$FAKE_TH_WT" ;;
esac
exit 0
SH
chmod +x "$FB/treehouse"
# Claude answers `auth status` signed in, for the worker account pin case.
cat > "$FB/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FB/claude"

t3_fake_start "$TMP_ROOT/server"

new_case() {  # <id> -> sets PROJ WT DATA STATE CONFIG for a fresh task
  local id=$1
  CASE="$TMP_ROOT/case-$id"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  DATA="$CASE/data"
  STATE="$CASE/state"
  CONFIG="$CASE/config"
  fm_git_worktree "$PROJ" "$WT" "fm/$id"
  git -C "$WT" checkout --quiet --detach
  mkdir -p "$DATA/$id" "$STATE" "$CONFIG"
  cat > "$DATA/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the t3 backend.

## Firstmate spec
Verify the t3 lifecycle behavior under test.
EOF
  touch "$STATE/.last-watcher-beat"
  printf 't3\n' > "$CONFIG/backend"
  t3_fake_credential "$CONFIG/t3-token"
  t3_fake_config '{}'
  : > "$T3_FAKE_LOG"
}

run_spawn() {  # <id> <args...> -> OUT, RC
  local id=$1
  shift
  OUT=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FAKE_TH_WT="$WT" T3_FAKE_LOG="$T3_FAKE_LOG" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$@" 2>&1 )
  RC=$?
}

neutral_root() {  # -> a minimal root whose guard is quiet
  local root="$CASE/neutral"
  mkdir -p "$root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/fm-guard.sh"
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

run_tool() {  # <script> <args...> -> OUT, RC
  local script=$1 neutral
  shift
  neutral=$(neutral_root)
  OUT=$( PATH="$FB:$PATH" T3_FAKE_LOG="$T3_FAKE_LOG" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" FM_SEND_SETTLE=0 \
    "$ROOT/bin/$script" "$@" 2>&1 )
  RC=$?
}

field() {  # <json> <key>
  node -e 'const d=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k], d); process.stdout.write(v===undefined?"":typeof v==="object"?JSON.stringify(v):String(v))' "$1" "$2"
}

meta() {  # <id> <key>
  bash -c '. "$1"; fm_meta_get "$2" "$3"' _ "$ROOT/bin/fm-backend.sh" "$STATE/$1.meta" "$2"
}

assert_untouched() {  # <id> <label>
  assert_absent "$STATE/$1.meta" "$2: no task record may be written"
  assert_not_contains "$(cat "$T3_FAKE_LOG")" '"treehouse":["get"' "$2: no worktree may be leased"
  assert_not_contains "$(cat "$T3_FAKE_LOG")" '"tool":"t3_thread_launch"' "$2: no T3 thread may be created"
}

test_spawn_claude_scout_into_leased_worktree() {
  local id=t3spawnz1 launch send doorbell rec
  new_case "$id"
  run_spawn "$id" --scout --harness claude --model claude-sonnet-5-5 --effort low
  expect_code 0 "$RC" "a claude scout spawn on t3 should succeed"$'\n'"$OUT"
  assert_contains "$OUT" "spawned $id harness=claude kind=scout window=fm-$id worktree=$WT" "spawn summary"
  assert_contains "$(cat "$T3_FAKE_LOG")" "{\"treehouse\":[\"get\",\"--lease\",\"--lease-holder\",\"$id\"]}" \
    "the spawn must lease its slot durably under the task id"
  assert_equals t3 "$(meta "$id" backend)" "meta backend"
  assert_equals "fm-$id" "$(meta "$id" window)" "meta window is the stable task alias"
  assert_equals "$WT" "$(meta "$id" worktree)" "meta worktree"
  assert_equals env-fake-1 "$(meta "$id" t3_environment_id)" "meta records the environment id"
  assert_equals "$T3_FAKE_URL" "$(meta "$id" t3_origin)" "meta records the origin"
  assert_equals claudeAgent "$(meta "$id" t3_provider_instance)" "meta records the provider instance"
  assert_contains "$(meta "$id" t3_thread_id)" "mcp:thread-" "meta records the thread id"
  assert_contains "$(meta "$id" t3_project_id)" "mcp:proj-" "meta records the T3 project"
  launch=$(t3_fake_calls t3_thread_launch)
  assert_equals "$WT" "$(field "$launch" workspaceStrategy.worktreePath)" "the thread is bound to the leased worktree"
  assert_equals full-access "$(field "$launch" runtimeMode)" "the thread runs at full access"
  assert_equals "" "$(field "$launch" message)" "the thread is created idle, before the record exists"
  send=$(t3_fake_calls t3_thread_send)
  assert_contains "$(field "$send" clientRequestId)" "fm-launch-$id-" "the launch brief is sent once under a launch request id"
  doorbell=$(field "$send" message)
  assert_contains "$doorbell" ": Firstmate operational input waiting: read '" "claude receives the record-backed launch doorbell"
  rec=${doorbell#*read \'}
  rec=${rec%%\'*}
  assert_contains "$(cat "$rec")" "FIRSTMATE_OP: v1 launch-brief:" "the doorbell names the encoded launch-brief record"
  assert_grep '"attribution":{"commit":"","pr":"","sessionUrl":false}' "$WT/.claude/settings.local.json" \
    "a T3 Claude worker gets the no-agent-trailer policy through its settings file"
  pass "fm-spawn.sh backend=t3: leases the slot, binds an idle thread, publishes t3 meta, then sends the launch doorbell"
}

test_spawn_codex_ship_sends_encoded_brief() {
  local id=t3codexz2 send
  new_case "$id"
  sed -i.bak '1i\
Delivery contract: mode=local-only
' "$DATA/$id/brief.md"
  run_spawn "$id" --mode local-only --yolo off --harness codex
  expect_code 0 "$RC" "a codex ship spawn on t3 should succeed"$'\n'"$OUT"
  assert_equals codex "$(meta "$id" t3_provider_instance)" "codex maps to T3's codex instance"
  send=$(t3_fake_calls t3_thread_send)
  assert_contains "$(field "$send" message)" $'\xE2\x81\xA3FIRSTMATE_OP: v1 launch-brief:' "codex receives the encoded launch brief inline"
  pass "fm-spawn.sh backend=t3: a codex ship receives the encoded launch-brief envelope"
}

test_spawn_refusals_leave_nothing() {
  local id
  id=t3refusesm
  new_case "$id"
  OUT=$( FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$CASE/projects" FM_SPAWN_NO_GUARD=1 PATH="$FB:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$CASE/subhome" claude --backend t3 --secondmate 2>&1 ); RC=$?
  [ "$RC" -ne 0 ] || fail "a t3 secondmate spawn must be refused"
  assert_contains "$OUT" "backend=t3 does not support --secondmate spawns" "secondmate refusal"
  assert_untouched "$id" "secondmate"

  id=t3refuseraw; new_case "$id"
  run_spawn "$id" --scout "claude --model x"
  [ "$RC" -ne 0 ] || fail "a raw launch on t3 must be refused"
  assert_contains "$OUT" "backend=t3 cannot run a raw launch command" "raw launch refusal"
  assert_untouched "$id" "raw launch"

  id=t3refusepi; new_case "$id"
  run_spawn "$id" --scout --harness pi
  [ "$RC" -ne 0 ] || fail "a pi worker on t3 must be refused"
  assert_contains "$OUT" "backend=t3 runs only claude and codex workers, not 'pi'" "harness refusal"
  assert_untouched "$id" "pi harness"

  id=t3refusepin; new_case "$id"
  mkdir -p "$CASE/acct"
  printf '%s\n' "$CASE/acct" > "$CONFIG/claude-account"
  run_spawn "$id" --scout --harness claude
  [ "$RC" -ne 0 ] || fail "a worker account pin on t3 must be refused"
  assert_contains "$OUT" "backend=t3 cannot apply this home's claude worker account pin" "pin refusal"
  assert_untouched "$id" "account pin"

  id=t3refuseperm; new_case "$id"
  printf 'auto\n' > "$CONFIG/claude-permission-mode"
  run_spawn "$id" --scout --harness claude
  [ "$RC" -ne 0 ] || fail "config/claude-permission-mode=auto on t3 must be refused"
  assert_contains "$OUT" "cannot honor config/claude-permission-mode=auto" "permission-mode refusal"
  assert_untouched "$id" "permission mode"

  id=t3refuseenv; new_case "$id"
  printf 'HOME\n' > "$CONFIG/launch-env-allowlist"
  run_spawn "$id" --scout --harness claude
  [ "$RC" -ne 0 ] || fail "config/launch-env-allowlist on t3 must be refused"
  assert_contains "$OUT" "backend=t3 cannot apply config/launch-env-allowlist" "launch-env refusal"
  assert_untouched "$id" "launch env"

  id=t3refusegate; new_case "$id"
  t3_fake_config '{"tools":["t3_thread_send","t3_thread_read","t3_environment_read"]}'
  run_spawn "$id" --scout --harness claude
  [ "$RC" -ne 0 ] || fail "a T3 without the thread tools must be refused"
  assert_contains "$OUT" "lacks t3_thread_launch" "gate refusal names the missing tool"
  assert_untouched "$id" "capability gate"

  id=t3refuseversion; new_case "$id"
  t3_fake_config '{"environmentId":"env-elsewhere"}'
  run_spawn "$id" --scout --harness claude
  [ "$RC" -ne 0 ] || fail "a T3 whose environment differs from the credential must be refused"
  assert_contains "$OUT" "not the env-fake-1 this credential was issued by" "environment refusal"
  assert_untouched "$id" "environment mismatch"

  id=t3refuseexpired; new_case "$id"
  t3_fake_credential "$CONFIG/t3-token" env-fake-1 $(( ($(date +%s) - 5) * 1000 ))
  run_spawn "$id" --scout --harness claude
  [ "$RC" -ne 0 ] || fail "an expired T3 credential must be refused"
  assert_contains "$OUT" "expired at" "expiry refusal"
  assert_untouched "$id" "expired credential"
  pass "fm-spawn.sh backend=t3: refuses secondmates, raw launches, other harnesses, pins, non-bypass Claude, env allowlists, the gate, a foreign environment, and expiry before any mutation"
}

test_spawn_abort_archives_thread_and_returns_lease() {
  local id=t3abortz3
  new_case "$id"
  t3_fake_config '{"failTools":{"t3_thread_send":{"code":"invalid_request","message":"refused"}}}'
  run_spawn "$id" --scout --harness claude
  [ "$RC" -ne 0 ] || fail "a refused launch brief must fail the spawn"
  assert_contains "$OUT" "T3 did not accept the launch brief for $id" "launch refusal message"
  assert_absent "$STATE/$id.meta" "a failed launch leaves no task record"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "the never-launched thread is archived"
  assert_contains "$(cat "$T3_FAKE_LOG")" "{\"treehouse\":[\"return\",\"--force\",\"--if-lease-holder\",\"$id\",\"$WT\"]}" \
    "the lease is handed back only for this task's holder"
  pass "fm-spawn.sh backend=t3: an aborted launch archives its thread, then returns the lease"
}

test_spawn_refuses_slot_of_another_clone() {
  local id=t3foreignslot other
  new_case "$id"
  other="$CASE/other-home-clone"
  fm_git_worktree "$other" "$CASE/other-wt" "fm/other"
  git -C "$CASE/other-wt" checkout --quiet --detach
  WT="$CASE/other-wt"
  run_spawn "$id" --scout --harness claude
  [ "$RC" -ne 0 ] || fail "a leased slot that belongs to another clone must be refused"
  assert_contains "$OUT" "belongs to $(cd "$other" && pwd -P), not" "the refusal names the clone that owns the slot"
  assert_absent "$STATE/$id.meta" "a refused slot leaves no task record"
  assert_not_contains "$(t3_fake_calls t3_thread_launch)" "t3_thread_launch" "no thread is created for another clone's slot"
  assert_contains "$(cat "$T3_FAKE_LOG")" "{\"treehouse\":[\"return\",\"--force\",\"--if-lease-holder\",\"$id\",\"$WT\"]}" \
    "the foreign slot's lease is handed back"
  pass "fm-spawn.sh backend=t3: refuses a leased slot that belongs to another home's clone and returns it"
}

test_peek_send_interrupt_and_control_refusals() {
  local id=t3ioz4 send rec
  new_case "$id"
  run_spawn "$id" --scout --harness claude
  expect_code 0 "$RC" "spawn for the io case"$'\n'"$OUT"
  run_tool fm-peek.sh "$id" 20
  expect_code 0 "$RC" "fm-peek should read the thread"$'\n'"$OUT"
  assert_contains "$OUT" "[t3 thread $(meta "$id" t3_thread_id) status=running" "peek renders the thread state"
  : > "$T3_FAKE_LOG"
  run_tool fm-send.sh "$id" "please check the report"
  expect_code 0 "$RC" "fm-send should record and ring"$'\n'"$OUT"
  rec="$STATE/$id.inbox/001.msg"
  assert_present "$rec" "the steer is durably recorded in the task inbox"
  send=$(t3_fake_calls t3_thread_send | tail -1)
  assert_contains "$(field "$send" message)" ": Firstmate instruction waiting: list '$(cd "$STATE" && pwd)/$id.inbox'/*.msg" \
    "the doorbell names the inbox by its absolute path"
  assert_not_contains "$(field "$send" message)" "please check the report" "the payload rides the inbox, not the thread"
  assert_contains "$(field "$send" clientRequestId)" "fm-" "every ring carries a request id"
  run_tool fm-control.sh "$id" interrupt
  expect_code 0 "$RC" "fm-control interrupt should succeed"$'\n'"$OUT"
  assert_contains "$OUT" "backend=t3 verified=endpoint cancel=confirmed" "a running turn's interrupt is confirmed"
  run_tool fm-control.sh "$id" interrupt
  assert_contains "$OUT" "cancel=not-running" "an idle thread's interrupt reports not-running"
  OUT=$( PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$ROOT/bin/fm-send.sh" "$id" --key Escape 2>&1 ); RC=$?
  expect_code 0 "$RC" "fm-send --key Escape maps to the native interrupt"$'\n'"$OUT"
  assert_contains "$(t3_fake_calls t3_thread_interrupt | tail -1)" '"threadId":"'"$(meta "$id" t3_thread_id)"'"' \
    "--key Escape interrupts the recorded thread"
  run_tool fm-control.sh "$id" exit
  [ "$RC" -ne 0 ] || fail "fm-control exit must refuse on t3 in P0"
  assert_contains "$OUT" "no recovery-grade agent-state classifier" "exit refusal reason"
  run_tool fm-control.sh "$id" relaunch --note x
  [ "$RC" -ne 0 ] || fail "fm-control relaunch must refuse on t3 in P0"
  pass "fm-peek/fm-send/fm-control on t3: bounded peek, absolute-path doorbell, confirmed interrupt, exit and relaunch refused"
}

scout_ready_for_teardown() {  # <id>
  printf 'report\n' > "$DATA/$1/report.md"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$STATE/$1.meta"
}

test_teardown_archives_before_returning_slot() {
  local id=t3teardownz5 log archive_line return_line
  new_case "$id"
  run_spawn "$id" --scout --harness claude
  expect_code 0 "$RC" "spawn for the teardown case"$'\n'"$OUT"
  scout_ready_for_teardown "$id"
  : > "$T3_FAKE_LOG"
  run_tool fm-teardown.sh "$id"
  expect_code 0 "$RC" "teardown should succeed after a proven archive"$'\n'"$OUT"
  assert_absent "$STATE/$id.meta" "teardown removes the record"
  log=$(cat "$T3_FAKE_LOG")
  archive_line=$(grep -n '"tool":"t3_thread_organize"' "$T3_FAKE_LOG" | head -1 | cut -d: -f1)
  return_line=$(grep -n '"treehouse":\["return"' "$T3_FAKE_LOG" | head -1 | cut -d: -f1)
  [ -n "$archive_line" ] && [ -n "$return_line" ] || fail "teardown must archive the thread and return the slot"$'\n'"$log"
  [ "$archive_line" -lt "$return_line" ] || fail "the thread must be archived before the slot returns"$'\n'"$log"
  pass "fm-teardown.sh backend=t3: archives the thread with a proven close before returning the slot"
}

test_teardown_refuses_unproven_close_and_unreachable_t3() {
  local id=t3teardownz6
  new_case "$id"
  run_spawn "$id" --scout --harness claude
  expect_code 0 "$RC" "spawn for the refusal case"$'\n'"$OUT"
  scout_ready_for_teardown "$id"
  t3_fake_config '{"archiveKeepsRun":true}'
  : > "$T3_FAKE_LOG"
  run_tool fm-teardown.sh "$id" --force
  [ "$RC" -ne 0 ] || fail "an archive that leaves an active run must stop teardown, even under --force"
  assert_present "$STATE/$id.meta" "an unproven close keeps the record"
  assert_not_contains "$(cat "$T3_FAKE_LOG")" '"treehouse":["return"' "an unproven close keeps the slot leased"
  t3_fake_config '{}'
  node -e '
const fs=require("fs"); const f=process.argv[1]; const d=JSON.parse(fs.readFileSync(f,"utf8"));
d.origin="http://127.0.0.1:9"; fs.writeFileSync(f, JSON.stringify(d));' "$CONFIG/t3-token"
  : > "$T3_FAKE_LOG"
  run_tool fm-teardown.sh "$id"
  [ "$RC" -ne 0 ] || fail "an unreachable T3 must stop teardown"
  assert_contains "$OUT" "teardown refused: T3 is needed to archive thread" "unreachable refusal reason"
  assert_present "$STATE/$id.meta" "an unreachable T3 keeps the record"
  assert_not_contains "$(cat "$T3_FAKE_LOG")" '"treehouse"' "an unreachable T3 changes nothing"
  pass "fm-teardown.sh backend=t3: an unproven close or an unreachable T3 keeps the record and the leased slot"
}

test_endpoint_validation_refuses_malformed_t3_meta() {
  local id=t3metaz7
  new_case "$id"
  fm_write_meta "$STATE/$id.meta" "window=fm-$id" "endpoint_task_id=$id" "worktree=$WT" "project=$PROJ" \
    "harness=claude" "kind=scout" "backend=t3" "t3_thread_id=mcp:thread-x"
  run_tool fm-teardown.sh "$id"
  [ "$RC" -ne 0 ] || fail "a t3 record without its environment id must be refused"
  assert_contains "$OUT" "T3 endpoint metadata for task $id is malformed or inconsistent" "malformed meta refusal"
  fm_write_meta "$STATE/$id.meta" "window=fm-$id" "endpoint_task_id=$id" "worktree=$WT" "project=$PROJ" \
    "harness=claude" "kind=scout" "backend=t3" "t3_thread_id=mcp:x@y" "t3_environment_id=env-fake-1"
  run_tool fm-teardown.sh "$id"
  [ "$RC" -ne 0 ] || fail "a t3 thread id carrying the target separator must be refused"
  pass "fm_backend_validate_task_endpoint backend=t3: refuses a record without a well-formed thread and environment"
}

test_spawn_claude_scout_into_leased_worktree
test_spawn_codex_ship_sends_encoded_brief
test_spawn_refusals_leave_nothing
test_spawn_abort_archives_thread_and_returns_lease
test_spawn_refuses_slot_of_another_clone
test_peek_send_interrupt_and_control_refusals
test_teardown_archives_before_returning_slot
test_teardown_refuses_unproven_close_and_unreachable_t3
test_endpoint_validation_refuses_malformed_t3_meta
