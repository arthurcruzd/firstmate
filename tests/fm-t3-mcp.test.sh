#!/usr/bin/env bash
# tests/fm-t3-mcp.test.sh - bin/fm-t3-mcp.mjs, the t3 backend's `/mcp`
# transport, driven through its CLI against tests/t3-fake-server.mjs: the
# captain-run sign-in, the capability gate, the environment-identity checks,
# credential expiry and permissions, and every thread verb's result shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-t3-mcp-tests)
trap 't3_fake_stop; fm_test_cleanup' EXIT
HELPER="$ROOT/bin/fm-t3-mcp.mjs"
CRED="$TMP_ROOT/config/t3-token"
WT="$TMP_ROOT/worktree"
mkdir -p "$WT"

mcp() {  # <verb> [args...] -> stdout in OUT, stderr in ERR, exit in RC
  local errf="$TMP_ROOT/stderr"
  OUT=$(node "$HELPER" "$@" --token-file "$CRED" 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
}

field() {  # <json> <key>
  node -e 'const d=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k], d); process.stdout.write(v===undefined?"":typeof v==="object"?JSON.stringify(v):String(v))' "$1" "$2"
}

test_login_writes_private_credential_and_never_prints_token() {
  local cli
  rm -f "$CRED"
  cli=$(t3_fake_t3_cli "$TMP_ROOT/cli")
  mcp login --url "$T3_FAKE_URL" --access full-access --t3 "$cli" --base-dir "$TMP_ROOT/t3home"
  expect_code 0 "$RC" "login should succeed against the fake server: $ERR"
  assert_equals true "$(field "$OUT" ok)" "login result should be ok"
  assert_equals env-fake-1 "$(field "$OUT" environmentId)" "login should record the server's environment id"
  assert_not_contains "$OUT$ERR" "tok-" "login must never print the access token"
  assert_not_contains "$OUT$ERR" "PAIR-OK" "login must never print the pairing code"
  [ "$(stat -f %Lp "$CRED" 2>/dev/null || stat -c %a "$CRED")" = 600 ] || fail "credential file must be mode 0600"
  assert_grep '"environment_id":"env-fake-1"' "$CRED" "credential must record the environment id"
  assert_grep '"origin":"'"$T3_FAKE_URL"'"' "$CRED" "credential must record the origin"
  assert_grep "auth pairing create --base-dir $TMP_ROOT/t3home --scope orchestration:read --scope orchestration:operate --ttl 2m" "$TMP_ROOT/cli/t3-cli.log" \
    "sign-in must mint a two-minute pairing code scoped to orchestration read and operate"
  assert_grep '"access":"full-access"' "$T3_FAKE_LOG" "the OAuth decision must carry the full-access ceiling"
  assert_grep '"pkce":true' "$T3_FAKE_LOG" "the token exchange must prove the PKCE verifier"
  pass "fm-t3-mcp login: PKCE sign-in writes a 0600 credential with the environment id and prints no secret"
}

test_login_refuses_other_ceilings() {
  local before after
  before=$(wc -l < "$T3_FAKE_LOG")
  mcp login --url "$T3_FAKE_URL" --access auto-accept-edits --t3 /bin/false
  expect_code 2 "$RC" "a non-full-access ceiling is invalid use"
  assert_contains "$ERR" "only the full-access ceiling" "the refusal should explain the ceiling"
  after=$(wc -l < "$T3_FAKE_LOG")
  assert_equals "$before" "$after" "a refused ceiling must not reach the server"
  pass "fm-t3-mcp login: refuses every ceiling but full-access before any request"
}

test_status_gate_and_protocol() {
  mcp status
  expect_code 0 "$RC" "status should pass the gate: $ERR"
  assert_equals env-fake-1 "$(field "$OUT" environmentId)" "status should report the environment id"
  assert_equals 0.0.46-nightly.fake "$(field "$OUT" serverVersion)" "status should report the server version"
  assert_grep '"protocol":"2025-06-18"' "$T3_FAKE_LOG" "every MCP request must carry protocol version 2025-06-18"
  t3_fake_config '{"sse":true}'
  mcp status
  expect_code 0 "$RC" "status should parse SSE replies too: $ERR"
  t3_fake_config '{}'
  pass "fm-t3-mcp status: gate passes over JSON and SSE replies with the 2025-06-18 protocol header"
}

test_gate_refuses_missing_tools() {
  t3_fake_config '{"tools":["t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_project_list","t3_project_create","t3_environment_read"]}'
  mcp status
  expect_code 4 "$RC" "a server without t3_thread_launch must be refused"
  assert_equals capability_gate "$(field "$OUT" error.code)" "the refusal should be the capability gate"
  assert_contains "$ERR" "t3_thread_launch" "the refusal should name the missing tool"
  t3_fake_config '{"tools":["t3_thread_launch","t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_project_list","t3_project_create"]}'
  mcp status
  expect_code 4 "$RC" "a server without t3_environment_read cannot prove its identity"
  t3_fake_config '{}'
  pass "fm-t3-mcp gate: refuses a server missing a required tool or its identity tool"
}

test_environment_mismatch_refused() {
  t3_fake_config '{"environmentId":"env-other"}'
  mcp status
  expect_code 4 "$RC" "a different environment behind the same origin must be refused"
  assert_equals environment_mismatch "$(field "$OUT" error.code)" "the refusal should be an environment mismatch"
  t3_fake_config '{}'
  mcp state --thread mcp:none --environment env-not-this-one
  expect_code 4 "$RC" "--environment must bind the call to the task's environment"
  assert_equals environment_mismatch "$(field "$OUT" error.code)" "--environment refusal code"
  pass "fm-t3-mcp: refuses a server whose environment id differs from the credential's or the task's"
}

test_expiry_and_permissions() {
  local before after
  t3_fake_credential "$CRED" env-fake-1 $(( ($(date +%s) - 60) * 1000 ))
  before=$(wc -l < "$T3_FAKE_LOG")
  mcp status
  expect_code 4 "$RC" "an expired credential must be refused"
  assert_equals credential_expired "$(field "$OUT" error.code)" "expired refusal code"
  after=$(wc -l < "$T3_FAKE_LOG")
  assert_equals "$before" "$after" "an expired credential must not reach the server"
  t3_fake_credential "$CRED" env-fake-1 $(( ($(date +%s) + 2 * 86400) * 1000 ))
  mcp status
  expect_code 0 "$RC" "a credential two days from expiry still works"
  assert_contains "$ERR" "warning: T3 credential expires in" "near expiry warns on stderr"
  assert_contains "$(field "$OUT" credentialWarning)" "expires in" "status reports the expiry warning"
  t3_fake_credential "$CRED" env-fake-1 "" 644
  mcp status
  expect_code 4 "$RC" "a credential readable by others must be refused"
  assert_equals credential_permissions "$(field "$OUT" error.code)" "permission refusal code"
  rm -f "$CRED"
  mcp status
  expect_code 4 "$RC" "a missing credential must be refused"
  assert_contains "$ERR" "login --url" "the missing-credential refusal names the captain's sign-in"
  t3_fake_credential "$CRED"
  pass "fm-t3-mcp credential: refuses expired, missing, and over-readable credentials, and warns before expiry"
}

test_revoked_credential_refused() {
  t3_fake_config '{"revoked":true}'
  mcp status
  expect_code 4 "$RC" "a revoked credential must be refused"
  assert_equals unauthorized "$(field "$OUT" error.code)" "revoked refusal code"
  t3_fake_config '{}'
  pass "fm-t3-mcp: a 401 from a revoked credential is a local refusal naming a fresh sign-in"
}

test_launch_idle_thread_bound_to_worktree() {
  local project call
  mcp project-ensure --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "project-ensure should create the project: $ERR"
  project=$(field "$OUT" projectId)
  assert_equals true "$(field "$OUT" created)" "first project-ensure creates"
  mcp project-ensure --root "$TMP_ROOT/proj"
  assert_equals "$project" "$(field "$OUT" projectId)" "second project-ensure finds the same project"
  assert_equals false "$(field "$OUT" created)" "second project-ensure does not create"
  mcp launch --project "$project" --title fm-a --harness claude --model claude-sonnet-5-5 --effort low --worktree "$WT"
  expect_code 0 "$RC" "launch should create an idle thread: $ERR"
  assert_equals claudeAgent "$(field "$OUT" instanceId)" "claude maps to T3's claudeAgent instance"
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals full-access "$(field "$call" runtimeMode)" "launch must request full access"
  assert_equals existing_worktree "$(field "$call" workspaceStrategy.type)" "launch must bind an existing worktree"
  assert_equals "$WT" "$(field "$call" workspaceStrategy.worktreePath)" "launch must bind the given worktree"
  assert_equals '[{"id":"effort","value":"low"}]' "$(field "$call" modelSelection.options)" "claude effort rides the effort option"
  assert_equals "" "$(field "$call" message)" "a launch without a message file creates an idle thread"
  mcp launch --project "$project" --title fm-b --harness codex --effort high --worktree "$WT"
  expect_code 0 "$RC" "codex default-model launch: $ERR"
  assert_equals gpt-5.6-luna "$(field "$OUT" model)" "default model is the instance's first catalog model"
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals '[{"id":"reasoningEffort","value":"high"}]' "$(field "$call" modelSelection.options)" "codex effort rides reasoningEffort"
  mcp launch --project "$project" --title fm-c --harness claude --model claude-haiku-4-5 --effort high --worktree "$WT"
  expect_code 0 "$RC" "a model without that effort still launches: $ERR"
  assert_contains "$ERR" "offers no 'high' effort" "an effort the model lacks is omitted with a warning"
  pass "fm-t3-mcp launch: idle full-access thread on the existing worktree, with catalog-resolved model and effort"
}

test_launch_refusals() {
  local project
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title x --harness grok --worktree "$WT"
  expect_code 4 "$RC" "grok is not a P0 harness"
  assert_equals harness_unsupported "$(field "$OUT" error.code)" "harness refusal code"
  mcp launch --project "$project" --title x --harness codex --model no-such-model --worktree "$WT"
  expect_code 4 "$RC" "a model outside T3's catalog is refused"
  assert_equals model_unsupported "$(field "$OUT" error.code)" "model refusal code"
  t3_fake_config '{"bindWorktree":"/somewhere/else"}'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title x --harness claude --worktree "$WT"
  expect_code 4 "$RC" "a thread bound to another worktree is refused"
  assert_equals binding_mismatch "$(field "$OUT" error.code)" "binding refusal code"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "a mis-bound thread is archived before refusing"
  t3_fake_config '{}'
  pass "fm-t3-mcp launch: refuses other harnesses, unknown models, and a binding T3 did not honor"
}

new_thread() {  # -> thread id
  local project
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title fm-t --harness claude --worktree "$WT"
  field "$OUT" threadId
}

test_send_capture_interrupt_archive() {
  local thread msg
  thread=$(new_thread)
  msg="$TMP_ROOT/msg"
  printf 'hello worker' > "$msg"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-1
  expect_code 0 "$RC" "send should start the idle thread: $ERR"
  assert_equals started "$(field "$OUT" delivery)" "an idle thread starts a turn"
  assert_contains "$(t3_fake_calls t3_thread_send | tail -1)" '"mode":"auto","clientRequestId":"req-1"' "send uses mode auto with the request id"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-1
  assert_equals started "$(field "$OUT" delivery)" "a repeated request id is the same message"
  mcp capture --thread "$thread" --lines 5
  expect_code 0 "$RC" "capture: $ERR"
  assert_contains "$OUT" "[t3 thread $thread status=running" "capture starts with the thread state"
  assert_contains "$OUT" "user_message/completed: hello worker" "capture renders activity items"
  mcp interrupt --thread "$thread"
  assert_equals confirmed "$(field "$OUT" cancel)" "interrupting a running turn is confirmed by the wait"
  mcp interrupt --thread "$thread"
  assert_equals not-running "$(field "$OUT" cancel)" "interrupting an idle thread reports not-running"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-2
  t3_fake_config '{"waitTimesOut":true}'
  mcp interrupt --thread "$thread" --timeout-ms 100
  assert_equals unconfirmed "$(field "$OUT" cancel)" "a wait that times out leaves the cancel unconfirmed"
  t3_fake_config '{"archiveKeepsRun":true}'
  mcp archive --thread "$thread" --timeout-ms 300
  expect_code 3 "$RC" "an archive that leaves an active run is not a proven close"
  assert_equals close_unproven "$(field "$OUT" error.code)" "unproven close code"
  t3_fake_config '{}'
  thread=$(new_thread)
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-3
  mcp archive --thread "$thread"
  expect_code 0 "$RC" "archive should prove the close: $ERR"
  assert_equals true "$(field "$OUT" closed)" "archive reports a proven close"
  assert_equals true "$(field "$OUT" archived)" "archive reads back archived"
  mcp archive --thread "$thread"
  expect_code 0 "$RC" "archiving an archived thread is the same end state"
  mcp state --thread "$thread"
  assert_equals true "$(field "$OUT" archived)" "state reports archived"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-4
  expect_code 3 "$RC" "an archived thread refuses messages as a typed T3 failure"
  assert_equals thread_not_sendable "$(field "$OUT" error.code)" "T3's own error code is carried"
  mcp archive --thread mcp:gone
  expect_code 0 "$RC" "a thread the verified server does not have is already closed"
  assert_equals true "$(field "$OUT" missing)" "archive of a missing thread reports missing"
  mcp state --thread mcp:gone
  assert_equals false "$(field "$OUT" exists)" "state of a missing thread reads exists:false"
  pass "fm-t3-mcp thread verbs: idempotent send, bounded capture, interrupt claims, and proven archive"
}

test_typed_failure_and_transport_errors() {
  local thread msg
  thread=$(new_thread)
  msg="$TMP_ROOT/msg"
  t3_fake_config '{"failTools":{"t3_thread_send":{"code":"invalid_request","message":"nope"}}}'
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-x
  expect_code 3 "$RC" "a tool error is a typed T3 failure"
  assert_equals invalid_request "$(field "$OUT" error.code)" "typed failure code"
  t3_fake_config '{}'
  node -e '
const fs=require("fs"); const f=process.argv[1]; const d=JSON.parse(fs.readFileSync(f,"utf8"));
d.origin="http://127.0.0.1:9"; fs.writeFileSync(f, JSON.stringify(d));' "$CRED"
  mcp status
  expect_code 1 "$RC" "an unreachable server is a transport failure"
  assert_equals transport "$(field "$OUT" error.code)" "transport failure code"
  t3_fake_credential "$CRED"
  pass "fm-t3-mcp: tool errors exit 3 with T3's code, an unreachable server exits 1"
}

test_telemetry_reported() {
  local tdir="$TMP_ROOT/telemetry"
  t3_fake_stop
  t3_fake_start "$tdir" T3CODE_TELEMETRY_ENABLED=false
  t3_fake_credential "$CRED"
  mcp status
  expect_code 0 "$RC" "status against a telemetry-off server: $ERR"
  if command -v lsof >/dev/null 2>&1; then
    assert_equals off "$(field "$OUT" telemetry)" "a loopback server started with telemetry off reads off"
    assert_not_contains "$ERR" "telemetry" "telemetry off warns nothing"
  fi
  t3_fake_stop
  t3_fake_start "$tdir"
  t3_fake_credential "$CRED"
  mcp status
  expect_code 0 "$RC" "status against a default server: $ERR"
  assert_not_equals off "$(field "$OUT" telemetry)" "a server without the setting is not reported off"
  assert_contains "$ERR" "T3CODE_TELEMETRY_ENABLED=false" "telemetry not proven off warns with the fix"
  pass "fm-t3-mcp status: reports telemetry off only when the server process proves it, and warns otherwise"
}

t3_fake_start "$TMP_ROOT/server"
test_login_writes_private_credential_and_never_prints_token
test_login_refuses_other_ceilings
test_status_gate_and_protocol
test_gate_refuses_missing_tools
test_environment_mismatch_refused
test_expiry_and_permissions
test_revoked_credential_refused
test_launch_idle_thread_bound_to_worktree
test_launch_refusals
test_send_capture_interrupt_archive
test_typed_failure_and_transport_errors
test_telemetry_reported
