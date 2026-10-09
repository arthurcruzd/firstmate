#!/usr/bin/env bash
# bin/backends/t3code.sh - the T3 Code orchestration-server adapter.
#
# T3 owns the agent session (it launches Claude or Codex itself) while
# Treehouse still owns the task worktree. Firstmate drives the T3 server only
# through its Orchestrator V2 `/mcp` endpoint, signed in as an OAuth
# `mcp-client`; bin/fm-t3-mcp.mjs owns that transport, the credential, the
# `tools/list` capability gate, and the environment-id check, and every
# primitive here is one call to it. There is no terminal: nothing is typed, a
# steer is a t3_thread_send, and Escape/Ctrl-C are a t3_thread_interrupt.
#
# Target string shape: the T3 thread id T3 assigned at launch.
#
# T3 sets environment variables per provider instance, never per thread, so
# every fact firstmate would type into a pane before launch (GOTMPDIR,
# COMPACT_ADVISER_DISABLE, FM_TASK_INBOX, the Git hook override, optional
# LAVISH_AXI_HOST, FM_TASK_ID, TRACEPARENT,
# and a secondmate's FM_* launch prefix) travels
# instead as per-directory harness config that bin/fm-spawn.sh writes into the
# launch directory before the first turn: `.claude/settings.local.json` `env`
# for Claude, `.codex/config.toml` `[shell_environment_policy] set` for Codex.
#
# Config (gitignored config/ of the active home):
#   t3code-token      the mcp-client credential the captain's
#                     `bin/fm-t3-mcp.mjs login` writes, mode 0600
#   t3code-instances  optional `harness=instanceId` lines (claude=claudeAgent,
#                     codex=codex by default)

# T3 has no composer, but the shared submit dispatcher in bin/fm-backend.sh
# prepares and reads the composer dialog sink around every adapter, so this
# adapter loads the same library every other backend does.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"
# The push normalizes thread levels into the shared transition record.
# shellcheck source=bin/fm-transition-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-transition-lib.sh"

FM_BACKEND_T3CODE_HELPER="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/fm-t3-mcp.mjs"

# Sourced only through fm_backend_source in bin/fm-backend.sh, which owns
# FM_BACKEND_CONFIG_DIR.
fm_backend_t3code_config_dir() {
  printf '%s' "$FM_BACKEND_CONFIG_DIR"
}

fm_backend_t3code_token_file() {
  printf '%s/t3code-token' "$(fm_backend_t3code_config_dir)"
}

fm_backend_t3code_tool_check() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=t3code selected but 'node' is not installed" >&2; return 1; }
  command -v treehouse >/dev/null 2>&1 || { echo "error: backend=t3code selected but 'treehouse' is not installed" >&2; return 1; }
}

# fm_backend_t3code_mcp <verb> [args...] - one helper call against this home's
# credential. It prints one JSON object (capture prints text) and exits as its
# header says: 0 ok, 1 transport or unexpected failure, 2 invalid use, 3 a
# typed T3 failure, 4 a local refusal (credential or capability gate), and
# thread-for-root's 5 and 6. Every failure prints one stderr line.
fm_backend_t3code_mcp() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=t3code selected but 'node' is not installed" >&2; return 1; }
  node "$FM_BACKEND_T3CODE_HELPER" "$@" --token-file "$(fm_backend_t3code_token_file)"
}

# fm_backend_t3code_json_get <key>: one top-level scalar from the helper's JSON
# on stdin. Fails when the object is not ok or lacks the key.
fm_backend_t3code_json_get() {  # <key>
  node -e '
const key = process.argv[1];
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok !== true) process.exit(1);
const v = d[key];
if (v === undefined || v === null || typeof v === "object") process.exit(1);
process.stdout.write(String(v));
' "$1"
}

# The credential, the capability gate (required t3_* tools and the
# environment id recorded at sign-in), and the telemetry warning, before any
# spawn or control mutation. The helper prints its own one-line reason.
fm_backend_t3code_runtime_check() {
  fm_backend_t3code_tool_check || return 1
  fm_backend_t3code_mcp status >/dev/null
}

fm_backend_t3code_project_ensure() {  # <project-path> -> project id
  local project=$1 real
  real=$(cd "$project" 2>/dev/null && pwd -P) || { echo "error: project path $project is not a directory" >&2; return 1; }
  # The fm- prefix keeps firstmate's projects apart from the owner's own T3
  # project names; matching stays by real path, so the title never binds.
  fm_backend_t3code_mcp project-ensure --root "$real" --title "fm-$(basename "$real")" | fm_backend_t3code_json_get projectId
}

# The harness -> T3 provider-option id table. Codex takes reasoningEffort and
# refuses max; Claude takes effort up to max. Anything else is not a T3 harness.
fm_backend_t3code_effort_option() {  # <harness> <effort> -> "<option-id> <value>"
  case "$1:$2" in
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max) printf 'effort %s' "$2" ;;
    codex:low|codex:medium|codex:high|codex:xhigh) printf 'reasoningEffort %s' "$2" ;;
    claude:*|codex:*) echo "error: backend=t3code cannot pass effort '$2' to harness '$1' (claude: low|medium|high|xhigh|max; codex: low|medium|high|xhigh)" >&2; return 1 ;;
    *) echo "error: backend=t3code supports only the claude and codex harnesses, not '$1'" >&2; return 1 ;;
  esac
}

fm_backend_t3code_instance_id() {  # <harness>
  local harness=$1 file line value
  case "$harness" in
    claude) value=claudeAgent ;;
    codex) value=codex ;;
    *) echo "error: backend=t3code supports only the claude and codex harnesses, not '$harness'" >&2; return 1 ;;
  esac
  file="$(fm_backend_t3code_config_dir)/t3code-instances"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "$harness="*) value=${line#*=} ;; esac
    done < "$file"
  fi
  [ -n "$value" ] || { echo "error: $file maps harness '$harness' to an empty instance id" >&2; return 1; }
  printf '%s' "$value"
}

fm_backend_t3code_model_selection() {  # <harness> <model> <effort> <project-id> -> JSON
  local harness=$1 model=$2 effort=$3 project_id=$4 instance option='' project
  instance=$(fm_backend_t3code_instance_id "$harness") || return 1
  if [ "$effort" != default ] && [ -n "$effort" ]; then
    option=$(fm_backend_t3code_effort_option "$harness" "$effort") || return 1
  fi
  if [ "$model" = default ] || [ -z "$model" ]; then
    project=$(fm_backend_t3code_mcp project-read --project "$project_id") || return 1
    # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
    printf '%s' "$project" | node -e '
const [projectId, instanceId, option] = process.argv.slice(1);
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
const selection = data.project && data.project.defaultModelSelection;
if (!selection) { console.error(`error: T3 project ${projectId} has no default model; pass --model with a slug from the T3 model catalog`); process.exit(1); }
if (selection.instanceId !== instanceId) { console.error(`error: T3 project ${projectId} defaults to instance ${selection.instanceId}, but config/t3code-instances selects ${instanceId}; pass --model explicitly`); process.exit(1); }
const out = { instanceId, model: selection.model };
if (option) { const [id, value] = option.split(" "); out.options = [{ id, value }]; }
else if (selection.options !== undefined) out.options = selection.options;
process.stdout.write(JSON.stringify(out));
' "$project_id" "$instance" "$option"
    return
  fi
  node -e '
const [instanceId, model, option] = process.argv.slice(1);
const out = { instanceId, model };
if (option) { const [id, value] = option.split(" "); out.options = [{ id, value }]; }
process.stdout.write(JSON.stringify(out));
' "$instance" "$model" "$option"
}

# fm_backend_t3code_thread_create: launch an idle thread at full access and
# print the id T3 assigned. A worktree launches with the existing_worktree
# strategy; an empty one launches at the project's own root, which is a
# secondmate's home. The helper reads the binding back and archives a thread
# T3 bound anywhere else. Exit 1 means the outcome is uncertain: a lost
# response can leave a thread behind whose id never came back, because
# t3_thread_launch has no idempotency key.
fm_backend_t3code_thread_create() {  # <project-id> <title> <branch> <worktree> <model-selection-json> -> thread id
  local project_id=$1 title=$2 branch=$3 worktree=$4 selection=$5 out rc
  local -a args=(launch --project "$project_id" --title "$title" --model-selection "$selection")
  [ -z "$branch" ] || args+=(--branch "$branch")
  [ -z "$worktree" ] || args+=(--worktree "$worktree")
  out=$(fm_backend_t3code_mcp "${args[@]}") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | fm_backend_t3code_json_get threadId || return 1
}

# fm_backend_t3code_thread_for_home <home>: the live T3 thread running the
# firstmate whose home is <home>, for away-mode supervisor discovery
# (bin/fm-t3-mcp.mjs thread-for-root owns the cwd match). Exactly one match
# prints its id (0); none prints nothing (1); more than one is an error naming
# the ids (2); an unreadable server is silent (1) so the caller falls through
# to its default.
fm_backend_t3code_thread_for_home() {  # <home> -> thread id
  local home=$1 real out rc
  real=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  out=$(fm_backend_t3code_mcp thread-for-root --root "$real" 2>/dev/null) && rc=0 || rc=$?
  case "$rc" in
    0) printf '%s' "$out" | fm_backend_t3code_json_get threadId ;;
    6)
      printf '%s' "$out" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.error("error: " + d.error.message);
'
      return 2
      ;;
    *) return 1 ;;
  esac
}

fm_backend_t3code_request_id() {
  printf 'fm-%s-%s-%s' "$(date +%s)" "${BASHPID:-$$}" "$RANDOM"
}

# One durable message: it starts an idle thread's next turn or steers the
# running one (t3_thread_send mode auto). The model selection was fixed at
# launch, so the optional third argument is accepted for the caller's
# symmetry and not sent.
fm_backend_t3code_turn_start() {  # <thread-id> <text> [model-selection-json]
  local thread=$1 text=$2 file rc=0
  # The brief rides a file: it is the one value too large to trust to argv.
  file=$(mktemp "${TMPDIR:-/tmp}/fm-t3code-msg.XXXXXX") || return 1
  printf '%s' "$text" > "$file" || { rm -f "$file"; return 1; }
  fm_backend_t3code_mcp send --thread "$thread" --message-file "$file" \
    --client-request-id "$(fm_backend_t3code_request_id)" >/dev/null || rc=$?
  rm -f "$file"
  return "$rc"
}

fm_backend_t3code_thread_state() {  # <thread-id>
  fm_backend_t3code_mcp state --thread "$1"
}

# fm_backend_t3code_probe: one word naming the thread's row in the status
# table, from its V2 thread status: idle, starting (preparing, queued,
# starting), running (running, or waiting while the run drains), blocked (an
# active run with a pending request, which T3 counts only while the run is
# live), ready (completed), interrupted (interrupted, rolled_back), cancelled
# (the run a T3 restart terminalized), error (failed), archived, http-404 (the
# verified server has no such thread), or http-failure (unreachable, refused,
# or unreadable).
fm_backend_t3code_probe() {  # <thread-id>
  local out
  out=$(fm_backend_t3code_thread_state "$1" 2>/dev/null) || { printf 'http-failure'; return 0; }
  printf '%s' "$out" | node -e '
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { d = null; }
const word = () => {
  if (!d || d.ok !== true) return "http-failure";
  if (d.exists === false) return "http-404";
  if (d.archived === true) return "archived";
  switch (d.status) {
    case "idle": return "idle";
    case "preparing": case "queued": case "starting": return "starting";
    case "running": case "waiting": return d.activeRunId && d.pendingRequestCount > 0 ? "blocked" : "running";
    case "completed": return "ready";
    case "interrupted": case "rolled_back": return "interrupted";
    case "cancelled": return "cancelled";
    case "failed": return "error";
    default: return "http-failure";
  }
};
process.stdout.write(word());
' 2>/dev/null || printf 'http-failure'
}

# fm_backend_t3code_turn_age: whole seconds since the thread's latest run
# boundary - its completion, or its start while it still runs. Fails when the
# thread is unreadable or carries no parseable run timestamp, so a caller that
# bounds a deferral by this age never defers on missing evidence.
fm_backend_t3code_turn_age() {  # <thread-id>
  local out
  out=$(fm_backend_t3code_thread_state "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const at = Date.parse(JSON.parse(require("fs").readFileSync(0, "utf8")).turnAt || "");
if (!Number.isFinite(at)) process.exit(1);
process.stdout.write(String(Math.max(0, Math.floor((Date.now() - at) / 1000))));
' 2>/dev/null
}

# The one status table: "<busy_state> <agent_state>" per probe row. Both
# halves are recovery-grade: busy and idle come from T3's own run state, and
# an archived thread is a stopped agent whose thread, transcript, and worktree
# binding are kept (exit archives; relaunch unarchives), so it reads dead,
# while only a thread the verified server does not have reads missing.
fm_backend_t3code_state_row() {  # <probe-row>
  case "$1" in
    starting|running|blocked) printf 'busy alive' ;;
    ready|idle|interrupted|cancelled) printf 'idle alive' ;;
    archived) printf 'idle dead' ;;
    error) printf 'unknown dead' ;;
    http-404) printf 'unknown missing' ;;
    *) printf 'unknown unreadable' ;;
  esac
}

fm_backend_t3code_busy_state() {  # <thread-id>
  local row
  row=$(fm_backend_t3code_state_row "$(fm_backend_t3code_probe "$1")")
  printf '%s' "${row%% *}"
}

fm_backend_t3code_agent_state() {  # <thread-id>
  local row
  row=$(fm_backend_t3code_state_row "$(fm_backend_t3code_probe "$1")")
  printf '%s' "${row#* }"
}

fm_backend_t3code_target_exists() {  # <thread-id>
  case "$(fm_backend_t3code_agent_state "$1")" in
    alive|dead) return 0 ;;
  esac
  return 1
}

# T3 has no composer to clear, so a live thread is always ready for a steer.
fm_backend_t3code_composer_state() {  # <thread-id> [expected-label] -> empty|unknown
  case "$(fm_backend_t3code_probe "$1")" in
    archived|http-404|http-failure) printf 'unknown' ;;
    *) printf 'empty' ;;
  esac
}

fm_backend_t3code_capture() {  # <thread-id> <lines>
  fm_backend_t3code_mcp capture --thread "$1" --lines "${2:-40}"
}

fm_backend_t3code_send_text_submit() {  # <thread-id> <text> <retries> <enter-sleep> <settle>
  if fm_backend_t3code_turn_start "$1" "$2"; then
    printf 'empty'
  else
    printf 'send-failed'
  fi
}

# fm_backend_t3code_native_interrupt <thread-id>: interrupt the running turn
# and print T3's own claim, confirmed by its run wait: confirmed,
# not-running, or unconfirmed.
fm_backend_t3code_native_interrupt() {  # <thread-id>
  fm_backend_t3code_mcp interrupt --thread "$1" | fm_backend_t3code_json_get cancel
}

fm_backend_t3code_send_key() {  # <thread-id> <key>
  local thread=$1 key=$2
  case "$key" in
    Escape|escape|Esc|esc|C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_t3code_native_interrupt "$thread" >/dev/null
      ;;
    Enter|enter) return 0 ;;
    *)
      echo "error: unsupported T3 key '$key'" >&2
      return 1
      ;;
  esac
}

# Interrupt any running turn, then archive the thread so it can never act in
# a returned slot, and succeed only on T3's read-back of archived:true with no
# active run (the helper's archive owns that proof). Archiving keeps the
# transcript visible in T3. Idempotent: an archived thread with no active run,
# or one the verified server no longer has, is already the end state.
fm_backend_t3code_kill() {  # <thread-id>
  local thread=$1 out
  out=$(fm_backend_t3code_thread_state "$thread") || return 1
  [ "$(printf '%s' "$out" | fm_backend_t3code_json_get exists)" = true ] || return 0
  if [ "$(printf '%s' "$out" | fm_backend_t3code_json_get archived)" = true ] \
    && ! printf '%s' "$out" | fm_backend_t3code_json_get activeRunId >/dev/null; then
    return 0
  fi
  if printf '%s' "$out" | fm_backend_t3code_json_get activeRunId >/dev/null; then
    fm_backend_t3code_native_interrupt "$thread" >/dev/null || return 1
  fi
  out=$(fm_backend_t3code_mcp archive --thread "$thread") || return 1
  [ "$(printf '%s' "$out" | fm_backend_t3code_json_get closed)" = true ]
}

# fm_backend_t3code_agent_stop: the control plane's `exit`. V2 `/mcp` has no
# session stop, so the agent is stopped the one way T3 offers: interrupt any
# running turn, then archive the thread, which ends its provider process. The
# thread, transcript, and worktree binding stay, and the archive is
# reversible, so the endpoint is preserved for a relaunch to resume. Success
# needs the same read-back the teardown close needs.
fm_backend_t3code_agent_stop() {  # <thread-id>
  fm_backend_t3code_kill "$1"
}

# fm_backend_t3code_thread_resume <thread-id> <model-selection-json>
# [worktree]: the relaunch half that keeps the endpoint. Prints `resumed` once
# T3 reads the thread back unarchived on <model-selection> and bound to
# <worktree> (the project root when empty), so the next message continues the
# same transcript in the copy holding the work; prints `rebind` when the thread
# is bound to another provider instance, which a thread that has run cannot
# leave, so the caller launches a new thread in the same worktree instead.
# Fails otherwise, a thread bound to any other workspace included.
fm_backend_t3code_thread_resume() {  # <thread-id> <model-selection-json> [worktree]
  local out
  local -a where=()
  [ -z "${3:-}" ] || where=(--worktree "$3")
  out=$(fm_backend_t3code_mcp resume --thread "$1" --model-selection "$2" ${where[@]+"${where[@]}"}) || return 1
  case "$(printf '%s' "$out" | fm_backend_t3code_json_get resumed)" in
    true) printf 'resumed' ;;
    false) printf 'rebind' ;;
    *) return 1 ;;
  esac
}

# fm_backend_t3code_restart_reconcile <thread-id> <marker-file> <message>: a
# T3 server restart terminalizes every in-flight run as `cancelled` and does
# not resume it, so the worker's turn ended without its own status line.
# Firstmate never cancels a run itself (its interrupt ends a run
# `interrupted`), so a latest run that reads `cancelled` and is not yet in
# <marker-file> is re-steered once with <message>, under a request id derived
# from that run so a retried send is the same message. Prints the reconciled
# run id and returns 0 after the send; returns 1 when there is nothing to
# reconcile; returns 2 when the read or send failed (the marker is untouched,
# so the next poll retries).
fm_backend_t3code_restart_reconcile() {  # <thread-id> <marker-file> <message>
  local thread=$1 marker=$2 message=$3 out run seen='' rid file rc=0
  out=$(fm_backend_t3code_thread_state "$thread" 2>/dev/null) || return 2
  [ "$(printf '%s' "$out" | fm_backend_t3code_json_get exists)" = true ] || return 1
  [ "$(printf '%s' "$out" | fm_backend_t3code_json_get archived)" = false ] || return 1
  [ "$(printf '%s' "$out" | fm_backend_t3code_json_get status)" = cancelled ] || return 1
  [ "$(printf '%s' "$out" | fm_backend_t3code_json_get latestRunStatus)" = cancelled ] || return 1
  run=$(printf '%s' "$out" | fm_backend_t3code_json_get latestRunId) || return 1
  [ ! -f "$marker" ] || IFS= read -r seen < "$marker" || true
  [ "$seen" != "$run" ] || return 1
  rid="fm-restart-$(printf '%s' "$run" | LC_ALL=C tr -c 'A-Za-z0-9._:-' '_')"
  file=$(mktemp "${TMPDIR:-/tmp}/fm-t3code-msg.XXXXXX") || return 2
  printf '%s' "$message" > "$file" || { rm -f "$file"; return 2; }
  fm_backend_t3code_mcp send --thread "$thread" --message-file "$file" --client-request-id "$rid" >/dev/null || rc=$?
  rm -f "$file"
  [ "$rc" -eq 0 ] || return 2
  printf '%s\n' "$run" > "$marker" || return 2
  printf '%s' "$run"
}

# --- watcher push -------------------------------------------------------------
# T3 refuses an mcp-client on its WebSocket stream, so the push is the helper's
# `watch` verb: a bounded t3_thread_wait on every active run, plus a read of
# each active run's pending-request count, inside the watcher's poll budget.
# A pending request on a running thread normalizes to `blocked` (the shared
# transition policy's only actionable status), an active run to `working`, and
# everything else to `idle` or `unknown`. A run that reached a terminal status
# since the last read touches the task's state/<id>.turn-ended wake
# notification, the same file a harness turn-end hook touches, so a Codex
# worker's turn end reaches the watcher as promptly as a Claude worker's. A
# `cancelled` run is left to fm_backend_t3code_restart_reconcile instead.

fm_backend_t3code_marker_key() {  # <thread-id>
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

fm_backend_t3code_escalation_marker() {  # <state-dir> <thread-id>
  printf '%s/.t3code-escalated-%s' "$1" "$(fm_backend_t3code_marker_key "$2")"
}

fm_backend_t3code_turn_marker() {  # <state-dir> <thread-id>
  printf '%s/.t3code-turn-%s' "$1" "$(fm_backend_t3code_marker_key "$2")"
}

fm_backend_t3code_events_capable() {  # [session]
  fm_backend_t3code_runtime_check >/dev/null 2>&1
}

# fm_backend_t3code_turn_seen <state-dir> <thread-id> <run-id> <run-status>:
# record the thread's latest run and touch its task's turn-ended notification
# on a fresh terminal edge: the same run seen active before, or a different
# run, but never a first sight (a watcher that just started must not replay
# an old turn end) and never a cancelled run.
fm_backend_t3code_turn_seen() {  # <state-dir> <thread-id> <run-id> <run-status>
  local state=$1 thread=$2 run=$3 status=$4 marker prev='' now meta task
  [ -n "$run" ] || return 0
  marker=$(fm_backend_t3code_turn_marker "$state" "$thread")
  [ ! -f "$marker" ] || IFS= read -r prev < "$marker" || true
  case "$status" in
    completed|failed|interrupted|rolled_back|cancelled) now="$run terminal" ;;
    *) now="$run active" ;;
  esac
  [ "$prev" != "$now" ] || return 0
  printf '%s\n' "$now" > "$marker" || return 1
  [ -n "$prev" ] && [ "${now##* }" = terminal ] && [ "$status" != cancelled ] || return 0
  meta=$(fm_backend_meta_for_window "$thread" "$state" 2>/dev/null) || return 0
  [ -n "$meta" ] || return 0
  task=${meta##*/}
  task=${task%.meta}
  touch "$state/$task.turn-ended"
}

# Returns 0 with one normalized actionable record, 1 after the watch returned
# (its budget spent, or early on a turn end or a run change, which the
# watcher's next cycle picks up), or 2 for the polling fallback. Dedupe is
# committed only after the watcher durably queues the wake, and a thread
# already escalated is passed back so its standing pending request cannot end
# every wait early.
fm_backend_t3code_wait_transition() {  # <session> <timeout-secs> <state-dir> <thread...>
  local timeout=$2 state=$3 out levels thread level run status marker record found='' rc=1 t threads='' escalated=''
  local -a extra=()
  shift 3
  [ "$#" -gt 0 ] || return 2
  case "$timeout" in ''|*[!0-9]*|0) timeout=30 ;; esac
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_t3code_events_capable || return 2
  fi
  for t in "$@"; do
    threads="${threads:+$threads,}$t"
    [ ! -e "$(fm_backend_t3code_escalation_marker "$state" "$t")" ] || escalated="${escalated:+$escalated,}$t"
  done
  [ -z "$escalated" ] || extra=(--escalated "$escalated")
  out=$(fm_backend_t3code_mcp watch --threads "$threads" --timeout-ms "$((timeout * 1000))" \
    ${extra[@]+"${extra[@]}"} 2>/dev/null) || return 2
  levels=$(printf '%s' "$out" | node -e '
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok !== true) process.exit(1);
for (const l of d.threads || []) {
  const level = !l.exists || l.archived ? "unknown" : l.blocked ? "blocked" : l.activeRunId ? "working" : "idle";
  console.log([l.threadId, level, l.latestRunId || "", l.latestRunStatus || ""].join("\t"));
}
') || return 2
  while IFS=$'\t' read -r thread level run status; do
    [ -n "$thread" ] || continue
    fm_backend_t3code_turn_seen "$state" "$thread" "$run" "$status" || true
    record=$(fm_transition_record "$thread" '' '' "$level" '')
    marker=$(fm_backend_t3code_escalation_marker "$state" "$thread")
    # These are levels read at the end of the watch, not an edge stream, so a
    # thread that is not blocked right now has no pending request left to
    # dedupe: any other level clears its marker, and its next pending request
    # escalates again even if the watch never saw it working in between.
    if [ "$(fm_transition_policy "$level")" = actionable ]; then
      if [ -z "$found" ] && [ ! -e "$marker" ]; then found=$record; rc=0; fi
    else
      rm -f "$marker"
    fi
  done <<EOF
$levels
EOF
  [ "$rc" -ne 0 ] || printf '%s' "$found"
  return "$rc"
}

fm_backend_t3code_commit_transition() {  # <state-dir> <session> <record>
  local thread
  thread=$(fm_transition_pane_id "$3")
  [ -n "$thread" ] || return 1
  : > "$(fm_backend_t3code_escalation_marker "$1" "$thread")"
}

fm_backend_t3code_clear_transition() {  # <state-dir> <thread-id>
  [ -n "$2" ] || return 0
  rm -f "$(fm_backend_t3code_escalation_marker "$1" "$2")" "$(fm_backend_t3code_turn_marker "$1" "$2")"
}

fm_backend_t3code_validate_harness() {  # <harness>
  case "$1" in
    claude|codex) return 0 ;;
    *) echo "error: backend=t3code runs only the claude and codex harnesses, not '$1'" >&2; return 1 ;;
  esac
}

# There is no pane: bin/fm-spawn.sh's launch-time typing helpers land here.
fm_backend_t3code_send_literal() {
  echo "error: backend=t3code has no pane to type into" >&2
  return 1
}
