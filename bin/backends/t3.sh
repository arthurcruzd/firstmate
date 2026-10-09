#!/usr/bin/env bash
# bin/backends/t3.sh - the experimental T3 Code session-provider adapter.
#
# T3 Code owns the agent session as a durable thread; Treehouse still owns the
# task worktree, which the thread is bound to. There is no terminal: every
# primitive is a call to T3's Orchestrator V2 `/mcp` endpoint through
# bin/fm-t3-mcp.mjs, the one owner of the transport, credential, capability
# gate, and environment-identity check. docs/t3-backend.md owns the operator
# contract and what P0 refuses.
#
# Target string shape: `<thread-id>@<environment-id>`, composed from the task
# record's t3_thread_id and t3_environment_id (bin/fm-backend.sh's
# fm_backend_target_of_meta). Every call passes the environment half to the
# helper, which refuses unless the server it reaches is that environment, so a
# thread is never read as missing on a different T3 server.
#
# Composer semantics: messages are discrete durable records, so there is no
# shared composer to hold pending text. The composer always reads `empty`,
# Enter and Ctrl+U are accepted no-ops, and Escape or Ctrl+C is a native turn
# interrupt.

FM_BACKEND_T3_HELPER="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/fm-t3-mcp.mjs"

fm_backend_t3_tool_check() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=t3 selected but 'node' is not installed" >&2; return 1; }
}

# fm_backend_t3_mcp <verb> [args...]: the helper against this home's credential.
fm_backend_t3_mcp() {
  fm_backend_t3_tool_check || return 1
  node "$FM_BACKEND_T3_HELPER" "$@" --token-file "${FM_BACKEND_CONFIG_DIR:-${FM_HOME:-.}/config}/t3-token"
}

# fm_backend_t3_json_get <key>: one top-level scalar from the helper's JSON on
# stdin. Exits 1 when the object is not ok or lacks the key.
fm_backend_t3_json_get() {  # <key>
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

# fm_backend_t3_split_target <target>: sets FM_BACKEND_T3_THREAD and
# FM_BACKEND_T3_ENV, or fails on anything but exactly one `@`.
fm_backend_t3_split_target() {  # <target>
  local target=${1:-}
  FM_BACKEND_T3_THREAD=${target%@*}
  FM_BACKEND_T3_ENV=${target##*@}
  case "$target" in
    *@*@*|*[[:space:]]*) return 1 ;;
    ?*@?*) ;;
    *) return 1 ;;
  esac
  [ -n "$FM_BACKEND_T3_THREAD" ] && [ -n "$FM_BACKEND_T3_ENV" ]
}

# fm_backend_t3_target_call <verb> <target> [args...]: a thread-scoped verb.
fm_backend_t3_target_call() {  # <verb> <target> [args...]
  local verb=$1 target=$2
  shift 2
  fm_backend_t3_split_target "$target" || {
    echo "error: '$target' is not a T3 thread target (<thread-id>@<environment-id>)" >&2
    return 1
  }
  fm_backend_t3_mcp "$verb" --thread "$FM_BACKEND_T3_THREAD" --environment "$FM_BACKEND_T3_ENV" "$@"
}

# fm_backend_t3_runtime_check: the credential, the capability gate, and the
# telemetry warning, before any spawn or cleanup mutation. The helper prints
# its own one-line reason on refusal.
fm_backend_t3_runtime_check() {
  fm_backend_t3_mcp status >/dev/null || {
    echo "error: backend=t3 is not usable; see the reason above and docs/t3-backend.md" >&2
    return 1
  }
}

fm_backend_t3_project_ensure() {  # <project-root>
  fm_backend_t3_mcp project-ensure --root "$1" | fm_backend_t3_json_get projectId
}

# fm_backend_t3_thread_create <project-id> <title> <harness> <model> <effort> <worktree>
# Creates an idle thread bound to <worktree> and prints
# "<thread-id>\t<environment-id>\t<origin>\t<instance-id>\t<model>".
fm_backend_t3_thread_create() {
  local out
  out=$(fm_backend_t3_mcp launch --project "$1" --title "$2" --harness "$3" \
    --model "${4:-default}" --effort "${5:-default}" --worktree "$6") || return 1
  node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const f = [d.threadId, d.environmentId, d.origin, d.instanceId, d.model];
if (d.ok !== true || f.some((v) => typeof v !== "string" || !v || /\s/.test(v))) process.exit(1);
process.stdout.write(f.join("\t"));
' <<<"$out"
}

# fm_backend_t3_send_message <target> <text> <client-request-id>: one durable
# message, started on an idle thread or steered into the running turn. A
# repeated request id is the same message.
fm_backend_t3_send_message() {  # <target> <text> <client-request-id>
  local target=$1 text=$2 rid=$3 file rc=0
  file=$(mktemp "${TMPDIR:-/tmp}/fm-t3-msg.XXXXXX") || return 1
  printf '%s' "$text" >"$file" || { rm -f "$file"; return 1; }
  fm_backend_t3_target_call send "$target" --message-file "$file" --client-request-id "$rid" >/dev/null || rc=$?
  rm -f "$file"
  return "$rc"
}

fm_backend_t3_request_id() {
  printf 'fm-%s-%s-%s' "$(date +%s)" "${BASHPID:-$$}" "$RANDOM"
}

fm_backend_t3_capture() {  # <target> <lines> [expected-label]
  fm_backend_t3_target_call capture "$1" --lines "${2:-40}"
}

fm_backend_t3_composer_state() {  # <target> [expected-label]
  printf 'empty'
}

# fm_backend_t3_native_interrupt <target>: interrupt the running turn and print
# T3's own claim: confirmed, not-running, or unconfirmed.
fm_backend_t3_native_interrupt() {  # <target>
  fm_backend_t3_target_call interrupt "$1" | fm_backend_t3_json_get cancel
}

fm_backend_t3_send_key() {  # <target> <key> [expected-label]
  case "$2" in
    Escape|C-c) fm_backend_t3_native_interrupt "$1" >/dev/null ;;
    Enter|C-u) return 0 ;;
    *) echo "error: unsupported T3 key '$2'" >&2; return 1 ;;
  esac
}

# fm_backend_t3_send_text_submit: one durable message under a fresh request id.
# Confirmed delivery prints nothing; a refused send prints send-failed.
fm_backend_t3_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  fm_backend_t3_send_message "$1" "$2" "$(fm_backend_t3_request_id)" || printf 'send-failed'
  return 0
}

# fm_backend_t3_target_exists: the thread exists on the recorded environment
# and is not archived.
fm_backend_t3_target_exists() {  # <target>
  local out
  out=$(fm_backend_t3_target_call state "$1" 2>/dev/null) || return 1
  [ "$(fm_backend_t3_json_get exists <<<"$out")" = true ] \
    && [ "$(fm_backend_t3_json_get archived <<<"$out")" = false ]
}

# fm_backend_t3_kill: archive the thread and succeed only on T3's read-back of
# archived:true with no active run, or when the recorded environment no longer
# has the thread. Anything else, an unreachable server included, is a close
# that did not happen.
fm_backend_t3_kill() {  # <target>
  local out
  out=$(fm_backend_t3_target_call archive "$1") || return 1
  [ "$(fm_backend_t3_json_get closed <<<"$out")" = true ]
}
