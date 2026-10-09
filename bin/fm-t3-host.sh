#!/usr/bin/env bash
# Run a Firstmate home's own primary session as a T3 Code thread, with a
# host-level wake relay in place of the Claude Stop hook's watcher ownership.
#
# A T3 thread's Claude session is a child of the T3 server, and T3 releases an
# idle provider session after 30 minutes (up to 4 hours while background work
# pins it), which would take a Stop-hook-owned watcher down with it. The relay
# is a long-running process outside the session - normally a user service -
# that owns this home's watcher and delivers each actionable close to the
# primary's thread as an ordinary T3 message, which also reloads an unloaded
# session. docs/t3-backend.md "Firstmate itself in T3" owns the operator
# contract; bin/fm-t3-host-lib.sh owns the ownership predicate the Stop hook,
# the turn-end guard, and the protocol renderer read.
#
# Usage:
#   fm-t3-host.sh launch [--model <id>] [--effort <level>] [--title <title>] [--message-file <file>]
#     Registers this home's checkout as a T3 project, writes FM_HOME into the
#     home's git-ignored .claude/settings.local.json (a T3 thread gets the T3
#     server's environment, not a per-thread one), launches the primary as a
#     full-access Claude thread bound to the checkout, and records it in
#     state/.t3-host. Refuses when the record names a thread that still exists
#     and is not archived; that thread is the primary.
#   fm-t3-host.sh adopt --thread <id>
#     Records an existing T3 thread, bound to this checkout and not archived,
#     as the primary, for a session started from T3's own UI.
#   fm-t3-host.sh relay
#     The wake relay loop, for a service manager. It records itself in
#     state/.t3-relay and exits when another live relay owns the home. While
#     the home needs supervision it runs bin/fm-watch-arm.sh in the foreground,
#     and on an actionable close (signal:, stale:, check:, heartbeat) sends the
#     reason lines to the recorded thread under an idempotent request id,
#     retrying until T3 accepts it; the durable wake queue holds the event in
#     the meantime. The next arm names the closed one as its predecessor.
#   fm-t3-host.sh install [--name <unit>]
#     Writes and enables a systemd user unit that runs `relay` (Linux only).
#     Default unit name: fm-t3-relay-<home basename>.service.
#   fm-t3-host.sh status
#     The recorded thread and its T3 state, and whether a live relay owns the
#     home. Changes nothing.
#
# Environment: FM_HOME (default: this checkout), FM_T3_RELAY_IDLE_POLL (seconds
# between need checks while the home needs no watcher, default 15).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HOST_RECORD="$STATE/.t3-host"
RELAY_RECORD="$STATE/.t3-relay"
MCP="$SCRIPT_DIR/fm-t3-mcp.mjs"
IDLE_POLL=${FM_T3_RELAY_IDLE_POLL:-15}
case "$IDLE_POLL" in ''|*[!0-9]*|0) IDLE_POLL=15 ;; esac

# shellcheck source=bin/fm-t3-host-lib.sh
. "$SCRIPT_DIR/fm-t3-host-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Environment:/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
}

die() { echo "fm-t3-host: $*" >&2; exit 1; }

record_get() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

json_get() {  # <key> (stdin JSON)
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s)[process.argv[1]];if(v!==undefined&&v!==null)process.stdout.write(String(v))})' "$1"
}

mcp() {
  FM_HOME="$FM_HOME" node "$MCP" "$@"
}

ensure_home_env_setting() {
  local file="$FM_HOME/.claude/settings.local.json" tmp
  mkdir -p "$FM_HOME/.claude"
  tmp=$(mktemp "$FM_HOME/.claude/.settings.local.XXXXXX") || return 1
  node -e '
const fs = require("fs");
const [file, home, out] = process.argv.slice(1);
let s = {};
try { s = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { if (e.code !== "ENOENT") { console.error(`unreadable ${file}: ${e.message}`); process.exit(1); } }
s.env = { ...(s.env ?? {}), FM_HOME: home };
fs.writeFileSync(out, JSON.stringify(s, null, 2) + "\n");' "$file" "$FM_HOME" "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

cmd_launch() {
  local model=claude-opus-5-5 effort=high title msg='' existing out project thread branch
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) model=${2:?}; shift 2 ;;
      --effort) effort=${2:?}; shift 2 ;;
      --title) title=${2:?}; shift 2 ;;
      --message-file) msg=${2:?}; shift 2 ;;
      *) die "unknown launch argument: $1" ;;
    esac
  done
  : "${title:=Firstmate ($(basename "$FM_HOME"))}"
  [ -f "$FM_HOME/AGENTS.md" ] && [ -d "$FM_HOME/bin" ] || die "$FM_HOME is not a Firstmate checkout"
  mkdir -p "$STATE"
  existing=$(record_get "$HOST_RECORD" thread)
  if [ -n "$existing" ]; then
    out=$(mcp state --thread "$existing") || die "cannot read recorded primary thread $existing: $out"
    if [ "$(printf '%s' "$out" | json_get exists)" = true ] && [ "$(printf '%s' "$out" | json_get archived)" != true ]; then
      die "the primary already runs as T3 thread $existing; send it a message instead of launching another"
    fi
  fi
  ensure_home_env_setting || die "could not write FM_HOME into $FM_HOME/.claude/settings.local.json"
  project=$(mcp project-ensure --root "$FM_HOME" --title "$title" | json_get projectId) || die "could not register $FM_HOME as a T3 project"
  [ -n "$project" ] || die "T3 did not report a project id for $FM_HOME"
  branch=$(git -C "$FM_HOME" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$msg" ]; then
    msg=$(mktemp) || die "mktemp failed"
    printf '%s\n' 'Session open. Run your session start and report the digest outcome briefly.' > "$msg"
  fi
  out=$(mcp launch --project "$project" --title "$title" --harness claude --model "$model" --effort "$effort" \
    --worktree "$FM_HOME" ${branch:+--branch "$branch"} --message-file "$msg") || die "T3 did not launch the primary: $out"
  thread=$(printf '%s' "$out" | json_get threadId)
  [ -n "$thread" ] || die "T3 did not report a thread id: $out"
  {
    printf 'thread=%s\n' "$thread"
    printf 'project=%s\n' "$project"
    printf 'environment=%s\n' "$(printf '%s' "$out" | json_get environmentId)"
    printf 'origin=%s\n' "$(printf '%s' "$out" | json_get origin)"
    printf 'launched=%s\n' "$(date +%s)"
  } > "$HOST_RECORD.tmp" && mv "$HOST_RECORD.tmp" "$HOST_RECORD"
  printf 'launched primary thread=%s project=%s home=%s\n' "$thread" "$project" "$FM_HOME"
}

cmd_adopt() {
  local thread='' out wt
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) thread=${2:?}; shift 2 ;;
      *) die "unknown adopt argument: $1" ;;
    esac
  done
  [ -n "$thread" ] || die "adopt needs --thread <id>"
  out=$(mcp state --thread "$thread") || die "cannot read T3 thread $thread: $out"
  [ "$(printf '%s' "$out" | json_get exists)" = true ] || die "T3 has no thread $thread"
  [ "$(printf '%s' "$out" | json_get archived)" != true ] || die "T3 thread $thread is archived"
  wt=$(printf '%s' "$out" | json_get worktreePath)
  [ "$(cd "${wt:-/nonexistent}" 2>/dev/null && pwd -P)" = "$(cd "$FM_HOME" && pwd -P)" ] || die "T3 thread $thread is bound to ${wt:-no worktree}, not $FM_HOME"
  ensure_home_env_setting || die "could not write FM_HOME into $FM_HOME/.claude/settings.local.json"
  mkdir -p "$STATE"
  { printf 'thread=%s\n' "$thread"; printf 'adopted=%s\n' "$(date +%s)"; } > "$HOST_RECORD.tmp" && mv "$HOST_RECORD.tmp" "$HOST_RECORD"
  printf 'adopted primary thread=%s home=%s\n' "$thread" "$FM_HOME"
}

# Deliver one wake to the primary thread. The request id is derived from the
# closed arm, so a retried delivery is the same T3 message.
deliver() {  # <request-id> <file>
  local rid=$1 file=$2 thread delay=5 out
  while :; do
    thread=$(record_get "$HOST_RECORD" thread)
    if [ -n "$thread" ]; then
      if out=$(mcp send --thread "$thread" --message-file "$file" --client-request-id "$rid" 2>&1); then
        printf 'fm-t3-host relay: delivered %s to %s (%s)\n' "$rid" "$thread" "$(printf '%s' "$out" | json_get delivery 2>/dev/null)"
        return 0
      fi
      printf 'fm-t3-host relay: delivery of %s failed, retrying in %ss: %s\n' "$rid" "$delay" "$(printf '%s' "$out" | tail -1)" >&2
    else
      printf 'fm-t3-host relay: no primary thread recorded in %s; holding %s\n' "$HOST_RECORD" "$rid" >&2
    fi
    fm_t3_relay_mine || return 1
    sleep "$delay"
    [ "$delay" -ge 60 ] || delay=$((delay * 2))
  done
}

fm_t3_relay_mine() {
  [ "$(record_get "$RELAY_RECORD" pid)" = "$$" ]
}

cmd_relay() {
  local out msg arm_pid rc pred='' n=0 started
  mkdir -p "$STATE"
  if fm_t3_relay_owns_home "$STATE" && ! fm_t3_relay_mine; then
    echo "fm-t3-host relay: another live relay owns $FM_HOME (pid $(record_get "$RELAY_RECORD" pid)); exiting" >&2
    exit 0
  fi
  started=$(fm_t3_relay_proc_started "$$")
  printf 'pid=%s\nstarted=%s\n' "$$" "$started" > "$RELAY_RECORD.tmp" && mv "$RELAY_RECORD.tmp" "$RELAY_RECORD"
  trap 'fm_t3_relay_mine && rm -f "$RELAY_RECORD"; kill "${arm_pid:-0}" 2>/dev/null; exit 0' TERM INT HUP
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  out=$(mktemp) || die "mktemp failed"
  msg=$(mktemp) || die "mktemp failed"
  echo "fm-t3-host relay: owning watcher for $FM_HOME (pid $$)"
  while fm_t3_relay_mine; do
    if ! fm_supervision_needed "$STATE"; then
      pred=''
      sleep "$IDLE_POLL"
      continue
    fi
    : > "$out"
    FM_HOME="$FM_HOME" FM_WATCH_PREDECESSOR_ARM_PID="$pred" "$SCRIPT_DIR/fm-watch-arm.sh" > "$out" 2>&1 &
    arm_pid=$!
    wait "$arm_pid"
    rc=$?
    pred=$arm_pid
    if grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out"; then
      n=$((n + 1))
      {
        printf '%s\n' 'Firstmate wake from the T3 wake relay:'
        grep -E '^(signal:|stale:|check:|heartbeat)' "$out" | head -8
        printf '%s\n' 'Run bin/fm-wake-drain.sh first and handle the wake. The relay owns watcher continuity; do not arm a watcher yourself.'
      } > "$msg"
      deliver "fm-t3-relay-$$-$arm_pid-$n" "$msg" || break
    elif [ "$rc" -ne 0 ]; then
      printf 'fm-t3-host relay: arm closed without a wake (rc=%s): %s\n' "$rc" "$(grep -E '^watcher:' "$out" | tail -1)" >&2
      pred=''
      sleep 10
    fi
  done
  rm -f "$out" "$msg"
}

cmd_install() {
  local name unit dir
  name="fm-t3-relay-$(basename "$FM_HOME").service"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) name=${2:?}; shift 2 ;;
      *) die "unknown install argument: $1" ;;
    esac
  done
  command -v systemctl >/dev/null 2>&1 || die "systemctl is not available; run '$0 relay' under this machine's own service manager"
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  unit="$dir/$name"
  mkdir -p "$dir"
  cat > "$unit" <<EOF
[Unit]
Description=Firstmate T3 wake relay for $FM_HOME

[Service]
Type=simple
WorkingDirectory=$FM_HOME
Environment=FM_HOME=$FM_HOME
Environment=PATH=$PATH
ExecStart=$FM_ROOT/bin/fm-t3-host.sh relay
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload && systemctl --user enable --now "$name" || die "could not enable $name"
  printf 'installed %s\n' "$unit"
}

cmd_status() {
  local thread
  thread=$(record_get "$HOST_RECORD" thread)
  printf 'home=%s\n' "$FM_HOME"
  printf 'thread=%s\n' "${thread:-none}"
  [ -z "$thread" ] || mcp state --thread "$thread" 2>/dev/null | sed 's/^/state=/'
  if fm_t3_relay_owns_home "$STATE"; then
    printf 'relay=live pid=%s\n' "$(record_get "$RELAY_RECORD" pid)"
  else
    printf 'relay=none\n'
  fi
}

case "${1:-}" in
  launch) shift; cmd_launch "$@" ;;
  adopt) shift; cmd_adopt "$@" ;;
  relay) shift; cmd_relay ;;
  install) shift; cmd_install "$@" ;;
  status) shift; cmd_status ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
