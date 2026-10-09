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
# session. docs/t3code-backend.md "Firstmate itself in T3" owns the operator
# contract; bin/fm-t3-host-lib.sh owns the ownership predicate the Stop hook,
# the turn-end guard, and the protocol renderer read.
#
# Usage:
#   fm-t3-host.sh launch [--model <id>] [--effort <level>] [--title <title>] [--message-file <file>]
#     Registers this script's Firstmate checkout (the code root, which is also
#     the home when FM_HOME is unset) as a T3 project, writes FM_HOME into the
#     checkout's git-excluded .claude/settings.local.json (a T3 thread gets the
#     T3 server's environment, not a per-thread one), launches the primary as a
#     full-access Claude thread on the project root (the instance comes from
#     config/t3code-instances, default claudeAgent), pins it, and records it in
#     the home's state/.t3-host. Refuses when the record names a thread that still exists
#     and is not archived; that thread is the primary.
#   fm-t3-host.sh adopt --thread <id>
#     Records an existing T3 thread, bound to the checkout and not archived,
#     as the primary, for a session started from T3's own UI.
#   fm-t3-host.sh relay
#     The wake relay loop, for a service manager. It records itself in
#     state/.t3-relay and exits when another live relay owns the home. While
#     state/.afk exists (away or quiet mode) the away daemon owns the watcher
#     and triage, and the relay runs that daemon itself as its own child,
#     aimed at the recorded thread, so T3 ending the session that entered the
#     mode cannot end supervision: it starts bin/fm-afk-start.sh when no live
#     daemon holds the home and no away-mode launch or stop is in progress,
#     restarts it if it exits while the flag stands, and stops it once the flag
#     clears. A daemon another owner already runs is left alone. Entering the
#     mode while a watcher cycle is open ends that cycle at once and delivers
#     nothing, so the daemon drains its wake from the durable queue.
#     Otherwise, while the home needs supervision, it runs bin/fm-watch-arm.sh in the foreground,
#     and on an actionable close (signal:, stale:, check:, heartbeat) sends the
#     reason lines to the recorded thread under an idempotent request id
#     (telling a session T3 reopened without its SessionStart hooks, found by a
#     dead session-lock holder, to run session start first),
#     retrying until T3 accepts it; the durable wake queue holds the event in
#     the meantime. The next arm names the closed one as its predecessor.
#   fm-t3-host.sh install [--name <unit>]
#     Runs `relay` as a user service: a systemd user unit on Linux (default
#     name fm-t3-relay-<home basename>.service), or an Aqua launch agent on
#     macOS (default label dev.firstmate.t3-relay.<home basename>, plist in
#     ~/Library/LaunchAgents, log in ~/Library/Logs). Rerunning it rewrites the
#     service and restarts the relay.
#   fm-t3-host.sh uninstall [--name <unit>]
#     Stops and removes that service; an absent service is already the end state.
#   fm-t3-host.sh status
#     The recorded thread and its T3 state, and whether a live relay owns the
#     home. Changes nothing.
#
# Environment: FM_HOME (default: this checkout), FM_T3_RELAY_IDLE_POLL (seconds
# between need checks while the home needs no watcher, and the pause before a
# hosted away daemon is restarted, default 15), FM_T3_RELAY_MODE_POLL
# (seconds between state/.afk checks while the relay waits on a watcher cycle
# or runs the away daemon, default 2).
# Test seams: FM_T3_RELAY_DAEMON_ENTRY replaces bin/fm-afk-start.sh as the
# command the relay runs for the away daemon, and FM_T3_RELAY_ARM_ENTRY
# replaces bin/fm-watch-arm.sh as its watcher cycle.
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
MODE_POLL=${FM_T3_RELAY_MODE_POLL:-2}
case "$MODE_POLL" in ''|*[!0-9]*|0) MODE_POLL=2 ;; esac
DAEMON_ENTRY=${FM_T3_RELAY_DAEMON_ENTRY:-$SCRIPT_DIR/fm-afk-start.sh}
ARM_ENTRY=${FM_T3_RELAY_ARM_ENTRY:-$SCRIPT_DIR/fm-watch-arm.sh}
RELAY_DAEMON_PID=

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
  local file="$FM_ROOT/.claude/settings.local.json" tmp exclude
  mkdir -p "$FM_ROOT/.claude"
  tmp=$(mktemp "$FM_ROOT/.claude/.settings.local.XXXXXX") || return 1
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions.
  node -e '
const fs = require("fs");
const [file, home, out] = process.argv.slice(1);
let s = {};
try { s = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { if (e.code !== "ENOENT") { console.error(`unreadable ${file}: ${e.message}`); process.exit(1); } }
s.env = { ...(s.env ?? {}), FM_HOME: home };
fs.writeFileSync(out, JSON.stringify(s, null, 2) + "\n");' "$file" "$FM_HOME" "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
  # Keep the checkout clean: the file is local state, never project content.
  if ! git -C "$FM_ROOT" check-ignore -q .claude/settings.local.json 2>/dev/null; then
    exclude=$(git -C "$FM_ROOT" rev-parse --git-path info/exclude 2>/dev/null) || return 0
    case "$exclude" in /*) ;; *) exclude="$FM_ROOT/$exclude" ;; esac
    mkdir -p "$(dirname "$exclude")" && printf '%s\n' '/.claude/settings.local.json' >> "$exclude"
  fi
}

cmd_launch() {
  local model=claude-opus-5-5 effort=high title msg='' existing out project thread branch instance selection
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
  [ -f "$FM_ROOT/AGENTS.md" ] && [ -d "$FM_ROOT/bin" ] || die "$FM_ROOT is not a Firstmate checkout"
  mkdir -p "$STATE"
  existing=$(record_get "$HOST_RECORD" thread)
  if [ -n "$existing" ]; then
    out=$(mcp state --thread "$existing") || die "cannot read recorded primary thread $existing: $out"
    if [ "$(printf '%s' "$out" | json_get exists)" = true ] && [ "$(printf '%s' "$out" | json_get archived)" != true ]; then
      die "the primary already runs as T3 thread $existing; send it a message instead of launching another"
    fi
  fi
  ensure_home_env_setting || die "could not write FM_HOME into $FM_ROOT/.claude/settings.local.json"
  project=$(mcp project-ensure --root "$FM_ROOT" --title "$title" | json_get projectId) || die "could not register $FM_ROOT as a T3 project"
  [ -n "$project" ] || die "T3 did not report a project id for $FM_ROOT"
  branch=$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$msg" ]; then
    msg=$(mktemp) || die "mktemp failed"
    printf '%s\n' 'Session open. Run your session start and report the digest outcome briefly.' > "$msg"
  fi
  instance=$(sed -n 's/^claude=//p' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/t3code-instances" 2>/dev/null | head -1)
  selection=$(node -e 'process.stdout.write(JSON.stringify({instanceId: process.argv[1], model: process.argv[2], options: [{id: "effort", value: process.argv[3]}]}))' \
    "${instance:-claudeAgent}" "$model" "$effort")
  # The root workspace strategy runs the thread in the project's own checkout,
  # which is how the away daemon's thread-for-root discovery finds a captain.
  out=$(mcp launch --project "$project" --title "$title" --model-selection "$selection" \
    ${branch:+--branch "$branch"} --message-file "$msg") || die "T3 did not launch the primary: $out"
  thread=$(printf '%s' "$out" | json_get threadId)
  [ -n "$thread" ] || die "T3 did not report a thread id: $out"
  mcp pin --thread "$thread" >/dev/null || echo "fm-t3-host: warning: could not pin thread $thread; pin it in T3's sidebar" >&2
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
  local thread='' out wt project tproject
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
  if [ -n "$wt" ]; then
    [ "$(cd "$wt" 2>/dev/null && pwd -P)" = "$(cd "$FM_ROOT" && pwd -P)" ] || die "T3 thread $thread is bound to $wt, not this checkout $FM_ROOT"
  else
    # A root-strategy thread runs in its project's own checkout.
    project=$(mcp project-ensure --root "$FM_ROOT" | json_get projectId) || die "could not resolve the T3 project for $FM_ROOT"
    tproject=$(mcp read --thread "$thread" --limit 1 | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);process.stdout.write(String((o.thread??o).projectId??""))})')
    [ -n "$project" ] && [ "$tproject" = "$project" ] || die "T3 thread $thread belongs to project ${tproject:-unknown}, not this checkout's $project"
  fi
  ensure_home_env_setting || die "could not write FM_HOME into $FM_ROOT/.claude/settings.local.json"
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

# True while bin/fm-afk-launch.sh holds its lock: an entry, refresh, or stop is
# rewriting the away-mode state, so the relay must not start a daemon under it.
relay_afk_launch_busy() {
  local pid
  pid=$(cat "$STATE/.afk-launch.lock/pid" 2>/dev/null) || return 1
  fm_pid_alive "$pid"
}

# One pass of away or quiet mode (the usage above): run the away daemon as this
# relay's child until state/.afk clears, it exits, or this relay is replaced.
relay_host_daemon() {
  local thread mode rc
  if daemon_lock_held_by_live_daemon || relay_afk_launch_busy; then
    sleep "$IDLE_POLL"
    return 0
  fi
  thread=$(record_get "$HOST_RECORD" thread)
  if [ -z "$thread" ]; then
    printf 'fm-t3-host relay: no primary thread recorded in %s; cannot run the away daemon\n' "$HOST_RECORD" >&2
    sleep "$IDLE_POLL"
    return 0
  fi
  mode=$(head -n 1 "$STATE/.afk" 2>/dev/null)
  printf 'fm-t3-host relay: running the %s-mode daemon for %s, aimed at %s\n' "${mode:-away}" "$FM_HOME" "$thread"
  # The launcher already prepared the flag and cleared stale artifacts; the
  # daemon cannot discover a thread from a service, so it is named here, and
  # the record-backed doorbell a Claude primary needs is one any thread opens.
  FM_HOME="$FM_HOME" FM_SUPERVISOR_BACKEND=t3code FM_SUPERVISOR_TARGET="$thread" \
    FM_DAEMON_PRIMARY_HARNESS=claude FM_AFK_STATE_PREPARED=1 "$DAEMON_ENTRY" &
  RELAY_DAEMON_PID=$!
  while kill -0 "$RELAY_DAEMON_PID" 2>/dev/null; do
    if [ ! -e "$STATE/.afk" ] || ! fm_t3_relay_mine; then
      kill -TERM "$RELAY_DAEMON_PID" 2>/dev/null
      break
    fi
    sleep "$MODE_POLL"
  done
  wait "$RELAY_DAEMON_PID"
  rc=$?
  RELAY_DAEMON_PID=
  printf 'fm-t3-host relay: the away daemon exited (rc=%s)\n' "$rc"
  # A daemon that exits while the flag stands is restarted after a pause; a
  # stop in progress clears the flag within it.
  [ ! -e "$STATE/.afk" ] || sleep "$IDLE_POLL"
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
  # shellcheck disable=SC2329 # Invoked by the trap below.
  relay_exit() {
    local child
    fm_t3_relay_mine && rm -f "$RELAY_RECORD"
    for child in ${arm_pid:-} ${RELAY_DAEMON_PID:-}; do kill "$child" 2>/dev/null; done
    exit 0
  }
  trap relay_exit TERM INT HUP
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  # The daemon-lock liveness helpers; sourcing enables errexit, which this
  # loop does not use.
  # shellcheck source=bin/fm-afk-start.sh
  . "$SCRIPT_DIR/fm-afk-start.sh"
  set +e
  out=$(mktemp) || die "mktemp failed"
  msg=$(mktemp) || die "mktemp failed"
  echo "fm-t3-host relay: owning watcher for $FM_HOME (pid $$)"
  while fm_t3_relay_mine; do
    # While state/.afk exists the away daemon owns the watcher and triage
    # (docs/t3code-backend.md "Away-mode supervisor support"), run here.
    if [ -e "$STATE/.afk" ]; then
      pred=''
      relay_host_daemon
      continue
    fi
    if ! fm_supervision_needed "$STATE"; then
      pred=''
      sleep "$IDLE_POLL"
      continue
    fi
    : > "$out"
    FM_HOME="$FM_HOME" FM_WATCH_PREDECESSOR_ARM_PID="$pred" "$ARM_ENTRY" > "$out" 2>&1 &
    arm_pid=$!
    # Entering away or quiet mode mid-cycle hands the watcher to the daemon at
    # once; the watcher queues every wake durably before it reports one.
    while kill -0 "$arm_pid" 2>/dev/null; do
      if [ -e "$STATE/.afk" ] || ! fm_t3_relay_mine; then
        kill -TERM "$arm_pid" 2>/dev/null
        break
      fi
      sleep "$MODE_POLL"
    done
    wait "$arm_pid"
    rc=$?
    pred=$arm_pid
    arm_pid=
    # A wake that closes once the mode began stays queued for the daemon.
    if [ -e "$STATE/.afk" ]; then
      pred=''
      continue
    fi
    if grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out"; then
      n=$((n + 1))
      {
        printf '%s\n' 'Firstmate wake from the T3 wake relay:'
        grep -E '^(signal:|stale:|check:|heartbeat)' "$out" | head -8
        # T3 reopens an unloaded session without running its SessionStart
        # hooks, so a dead lock holder means this message starts a new session.
        fm_t3_session_holder_alive "$STATE" || printf '%s\n' "$FM_T3_REOPENED_SESSION_HINT"
        printf '%s\n' 'Run bin/fm-wake-drain.sh first and handle the wake. The relay owns watcher continuity; do not arm a watcher yourself.'
      } > "$msg"
      deliver "fm-t3-relay-$$-$pred-$n" "$msg" || break
    elif [ "$rc" -ne 0 ]; then
      printf 'fm-t3-host relay: arm closed without a wake (rc=%s): %s\n' "$rc" "$(grep -E '^watcher:' "$out" | tail -1)" >&2
      pred=''
      sleep 10
    fi
  done
  rm -f "$out" "$msg"
}

service_name() {  # [--name <name>] -> the unit name or launchd label
  local name=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) name=${2:?}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  if [ -z "$name" ]; then
    if [ "$(uname -s)" = Darwin ]; then
      name="dev.firstmate.t3-relay.$(basename "$FM_HOME")"
    else
      name="fm-t3-relay-$(basename "$FM_HOME").service"
    fi
  fi
  case "$name" in ''|*[!A-Za-z0-9._@-]*) die "unsafe service name: $name" ;; esac
  printf '%s' "$name"
}

launchd_plist() {  # <label>
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$1"
}

# An Aqua launch agent in the login session, where this host's T3 server runs
# too, so the relay lives exactly as long as the server it sends to can.
install_launchd() {  # <label>
  local label=$1 plist log value tmp
  plist=$(launchd_plist "$label")
  log="$HOME/Library/Logs/$label.log"
  for value in "$FM_ROOT" "$FM_HOME" "$PATH" "$HOME"; do
    case "$value" in *'&'*|*'<'*|*'>'*) die "cannot embed $value in a property list" ;; esac
  done
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
  tmp="$plist.tmp.$$"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">' '<dict>'
    printf '\t<key>Label</key>\n\t<string>%s</string>\n' "$label"
    printf '\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>%s</string>\n\t\t<string>relay</string>\n\t</array>\n' "$FM_ROOT/bin/fm-t3-host.sh"
    printf '\t<key>WorkingDirectory</key>\n\t<string>%s</string>\n' "$FM_ROOT"
    printf '\t<key>EnvironmentVariables</key>\n\t<dict>\n'
    printf '\t\t<key>FM_HOME</key>\n\t\t<string>%s</string>\n' "$FM_HOME"
    printf '\t\t<key>HOME</key>\n\t\t<string>%s</string>\n' "$HOME"
    printf '\t\t<key>PATH</key>\n\t\t<string>%s</string>\n' "$PATH"
    printf '\t</dict>\n'
    printf '\t<key>LimitLoadToSessionType</key>\n\t<string>Aqua</string>\n'
    printf '\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>KeepAlive</key>\n\t<true/>\n'
    printf '\t<key>StandardOutPath</key>\n\t<string>%s</string>\n' "$log"
    printf '\t<key>StandardErrorPath</key>\n\t<string>%s</string>\n' "$log"
    printf '%s\n' '</dict>' '</plist>'
  } > "$tmp" || { rm -f "$tmp"; die "could not write $plist"; }
  mv "$tmp" "$plist" || { rm -f "$tmp"; die "could not write $plist"; }
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" || die "could not load $label into gui/$(id -u); an Aqua login session is required"
  printf 'installed %s\n' "$plist"
}

cmd_install() {
  local name unit dir
  name=$(service_name "$@") || exit 1
  if [ "$(uname -s)" = Darwin ]; then
    install_launchd "$name"
    return
  fi
  command -v systemctl >/dev/null 2>&1 || die "systemctl is not available; run '$0 relay' under this machine's own service manager"
  # A caller outside a login shell, such as a remote job, still reaches the
  # user manager through its runtime directory.
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  unit="$dir/$name"
  mkdir -p "$dir"
  cat > "$unit" <<EOF
[Unit]
Description=Firstmate T3 wake relay for $FM_HOME

[Service]
Type=simple
WorkingDirectory=$FM_ROOT
Environment=FM_HOME=$FM_HOME
Environment=PATH=$PATH
ExecStart=$FM_ROOT/bin/fm-t3-host.sh relay
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  if ! systemctl --user daemon-reload || ! systemctl --user enable "$name" || ! systemctl --user restart "$name"; then
    die "could not enable $name"
  fi
  printf 'installed %s\n' "$unit"
}

cmd_uninstall() {
  local name
  name=$(service_name "$@") || exit 1
  if [ "$(uname -s)" = Darwin ]; then
    launchctl bootout "gui/$(id -u)/$name" >/dev/null 2>&1 || true
    rm -f "$(launchd_plist "$name")"
  else
    command -v systemctl >/dev/null 2>&1 || die "systemctl is not available"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    systemctl --user disable --now "$name" >/dev/null 2>&1 || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$name"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  printf 'uninstalled %s\n' "$name"
}

cmd_status() {
  local thread
  thread=$(record_get "$HOST_RECORD" thread)
  printf 'home=%s\n' "$FM_HOME"
  printf 'checkout=%s\n' "$FM_ROOT"
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
  uninstall) shift; cmd_uninstall "$@" ;;
  status) shift; cmd_status ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
