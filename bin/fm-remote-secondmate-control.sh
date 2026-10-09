#!/usr/bin/env bash
# Host-local lifecycle control for the remote secondmate home selected by fm-on.
#
# Usage:
#   fm-remote-secondmate-control.sh launch <id> <harness> <model|-> <effort|-> herdr|t3code [traceparent]
#   fm-remote-secondmate-control.sh relaunch <id> <harness> <model|default|-> <effort|default|->
#   fm-remote-secondmate-control.sh state <id>
#   fm-remote-secondmate-control.sh route <id>
#   fm-remote-secondmate-control.sh send <id> <message> [fire-and-forget]
#   fm-remote-secondmate-control.sh key <id> <key>
#   fm-remote-secondmate-control.sh interrupt <id>
#   fm-remote-secondmate-control.sh capture <id> [lines]
#   fm-remote-secondmate-control.sh observe <id>
#   fm-remote-secondmate-control.sh sync <id> [<parent-commit>]
#   fm-remote-secondmate-control.sh update <id>
#   fm-remote-secondmate-control.sh release <id>
#   fm-remote-secondmate-control.sh retire <id> [--force]
#
# Remote placement ends here. The parent selects the runtime that hosts the
# second-mate agent from its route's registry endpoint, never from this home's
# config/backend, and launch accepts exactly two:
#   herdr   the dedicated fm-remote Herdr session; the interactive default
#           session remains for the user's work.
#   t3code  a thread on this host's own T3 Code server, signed in with this
#           home's own config/t3code-token. Launch also records the thread as
#           the home's T3 host thread and installs the home's wake relay
#           (bin/fm-t3-host.sh install), which owns the mate's watcher outside
#           the session so supervision survives T3 unloading an idle mate, and
#           the mate's own workers launch as T3 threads on this server.
# fm-spawn/fm-send/fm-teardown keep owning the local endpoint mechanics.
# A Herdr-hosted mate's own workers keep their ordinary backend selection.
# bin/fm-remote-doctor.sh owns that host's readiness for either endpoint.
# docs/remote-secondmates.md owns why.
#
# interrupt runs the ordinary control plane's interrupt here and prints its
# verdict, so a T3-hosted mate reports T3's own cancel claim. release closes
# the recorded endpoint of an idle mate and sets its record aside, so the parent
# can move the mate to the other endpoint (bin/fm-remote-secondmate-move.sh);
# the home, its steering inbox, and its work are untouched.
#
# With <parent-commit>, sync follows the PARENT PRIMARY's default-branch commit,
# which the parent resolves on its own checkout and passes in, so a remote home
# tracks the primary exactly like a local one instead of stopping at whatever
# this host's Firstmate copy happens to hold. Omitting <parent-commit> targets
# this host's own code-root HEAD instead, which is what /updatefirstmate wants
# after it has refreshed that
# code root from origin. Because this home is a standalone clone, the target
# commit is imported here first and the fast-forward itself is the shared one in
# bin/fm-ff-lib.sh, so the clean, ancestry, and branch guards have a single owner.
# A private parent-route state directory stores only the remote secondmate
# agent's endpoint record; the home's own
# state/*.meta remains reserved for workers the secondmate supervises.
# Retirement closes only this secondmate's panes or workspace and never
# stops fm-remote or removes a sibling secondmate's workspace or panes.
#
# Relaunch is not a second lifecycle implementation: it runs the ORDINARY local
# control plane here, because from this host the mate is a plain local
# secondmate. cmd_relaunch below owns why the parent must hand it the profile.
# It ends by printing the same route block `route` prints, so a caller that
# invoked it directly (rather than through bin/fm-remote-secondmate-relaunch.sh,
# which reads this block to keep the parent's own record in sync) still gets
# the confirmed identity.
#
# The optional launch traceparent is the per-task W3C trace-context carrier the
# PARENT home resolved for this secondmate; this host only delivers it to the
# pane, and fm-spawn validates it (bin/fm-trace-context-lib.sh). Omitting it is
# the default-off path. print_route echoes the carrier the endpoint actually
# holds, including for an already-alive endpoint that was not relaunched, so the
# parent records the identity the agent really received rather than an intent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
CONTROL_STATE="$TARGET_HOME/state/parent-route"
CONTROL_DATA="$TARGET_HOME/data/.parent-route"
REMOTE_HERDR_SESSION=fm-remote

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-t3-host-lib.sh
. "$SCRIPT_DIR/fm-t3-host-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^# With <parent-commit>/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac; }

validate_home() { # <id> [allow-absent]
  local id=$1 allow_absent=${2:-no} marker
  if [ ! -e "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] && [ "$allow_absent" = yes ]; then return 2; fi
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "remote secondmate home is unavailable or unsafe"
  [ -f "$TARGET_HOME/.fm-secondmate-home" ] && [ ! -L "$TARGET_HOME/.fm-secondmate-home" ] \
    || die "remote home is not a seeded secondmate home"
  marker=$(cat "$TARGET_HOME/.fm-secondmate-home")
  [ "$marker" = "$id" ] || die "remote home belongs to $marker, not $id"
  [ -f "$TARGET_HOME/AGENTS.md" ] && [ -d "$TARGET_HOME/bin" ] || die "remote home is not a Firstmate checkout"
}

meta_path() { printf '%s/%s.meta\n' "$CONTROL_STATE" "$1"; }

remote_endpoint_load() {
  local id=$1 herdr_session
  REMOTE_ENDPOINT_ERROR=
  REMOTE_ENDPOINT_META=$(meta_path "$id")
  if ! fm_backend_validate_task_endpoint "$REMOTE_ENDPOINT_META" "$id" 2>/dev/null; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint metadata is invalid; refusing access until it is explicitly migrated"
    return 1
  fi
  REMOTE_ENDPOINT_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  REMOTE_ENDPOINT_TARGET=$FM_BACKEND_VALIDATED_TARGET
  case "$REMOTE_ENDPOINT_BACKEND" in
    herdr) ;;
    t3code)
      # The thread id T3 assigned at launch; there is no session to confine.
      case "$REMOTE_ENDPOINT_TARGET" in
        mcp:?*) return 0 ;;
      esac
      REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint target '$REMOTE_ENDPOINT_TARGET' is not a T3 thread id; refusing access until it is explicitly migrated"
      return 1
      ;;
    *)
      REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND', expected 'herdr' or 't3code'; refusing access until it is explicitly migrated"
      return 1
      ;;
  esac
  herdr_session=$(fm_backend_meta_exact_value "$REMOTE_ENDPOINT_META" herdr_session 2>/dev/null || true)
  if [ "$herdr_session" != "$REMOTE_HERDR_SESSION" ]; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded in Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
    return 1
  fi
  case "$REMOTE_ENDPOINT_TARGET" in
    "$REMOTE_HERDR_SESSION":?*) ;;
    *)
      REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint target '$REMOTE_ENDPOINT_TARGET' is outside Herdr session '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
      return 1
      ;;
  esac
}

remote_endpoint_require() {
  remote_endpoint_load "$1" || die "$REMOTE_ENDPOINT_ERROR"
}

state_value() { # <id>; prints recovery-grade state
  local id=$1 meta
  meta=$(meta_path "$id")
  [ -f "$meta" ] && [ ! -L "$meta" ] || { printf 'missing\n'; return 0; }
  if ! remote_endpoint_load "$id"; then
    printf 'error: %s\n' "$REMOTE_ENDPOINT_ERROR" >&2
    printf 'unverified\n'
    return 0
  fi
  fm_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n'
}

print_route() { # <id>
  local id=$1 harness model effort traceparent
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  model=$(fm_meta_get "$REMOTE_ENDPOINT_META" model)
  effort=$(fm_meta_get "$REMOTE_ENDPOINT_META" effort)
  traceparent=$(fm_meta_get "$REMOTE_ENDPOINT_META" traceparent)
  printf 'schema=fm-remote-secondmate-control.v1\n'
  printf 'backend=%s\n' "$REMOTE_ENDPOINT_BACKEND"
  printf 'target=%s\n' "$REMOTE_ENDPOINT_TARGET"
  [ "$REMOTE_ENDPOINT_BACKEND" != herdr ] || printf 'herdr_session=%s\n' "$REMOTE_HERDR_SESSION"
  printf 'harness=%s\n' "$harness"
  printf 'model=%s\n' "$model"
  printf 'effort=%s\n' "$effort"
  [ -z "$traceparent" ] || printf 'traceparent=%s\n' "$traceparent"
}

cmd_route() {
  local id=$1 meta
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    die "remote secondmate has no endpoint metadata"
  fi
  print_route "$id"
}

cmd_launch() {
  local id=$1 harness=$2 model=$3 effort=$4 selected_backend=$5 traceparent=${6:-}
  local current meta out herdr_session

  validate_id "$id"
  validate_home "$id"
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *) die "unverified remote secondmate harness: $harness" ;;
  esac
  case "$effort" in -|low|medium|high|xhigh|max|ultra) ;; *) die "invalid remote secondmate effort: $effort" ;; esac
  if [ "$effort" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
  fi
  # Both endpoints outlive every SSH disconnection a remote route depends on:
  # Herdr's server belongs to the GUI login session, and this host's T3 server
  # is a user service that owns its threads. bin/fm-remote-doctor.sh is the
  # readiness owner for each.
  case "$selected_backend" in
    herdr) ;;
    t3code)
      case "$harness" in claude|codex) ;; *) die "a T3-hosted remote secondmate runs only the claude or codex harness, not '$harness'" ;; esac
      [ -f "$TARGET_HOME/bin/fm-t3-host.sh" ] \
        || die "remote home's Firstmate checkout predates the T3 wake relay; sync it to a commit that has bin/fm-t3-host.sh first"
      ;;
    *) die "a remote secondmate runs only on the herdr or t3code backend, not '$selected_backend'" ;;
  esac
  mkdir -p "$CONTROL_STATE" "$CONTROL_DATA"
  meta=$(meta_path "$id")
  if [ -f "$meta" ]; then
    remote_endpoint_require "$id"
    if [ "$REMOTE_ENDPOINT_BACKEND" != "$selected_backend" ]; then
      die "remote secondmate $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND', not '$selected_backend'; move it with bin/fm-remote-secondmate-move.sh, which releases the old endpoint first"
    fi
    current=$(fm_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n')
    case "$current" in
      alive)
        print_route "$id"
        return 0
        ;;
      dead)
        fm_backend_kill "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null \
          || die "could not remove the confirmed agent-less endpoint"
        ;;
      missing) ;;
      *) die "remote endpoint state is $current; refusing duplicate launch" ;;
    esac
  fi
  # The parent owns both convergence legs before it asks for this launch: it
  # already fast-forwarded this home to ITS primary commit and pushed inherited
  # local material, so this spawn must not redo either against this host's own
  # Firstmate copy, which would target the wrong checkout.
  ARGS=("$id" "$TARGET_HOME" --secondmate --harness "$harness" --backend "$selected_backend")
  [ "$model" = - ] || ARGS+=(--model "$model")
  [ "$effort" = - ] || ARGS+=(--effort "$effort")
  [ -z "$traceparent" ] || ARGS+=(--traceparent "$traceparent")
  # A T3-hosted mate's own workers are T3 threads on this same server, whatever
  # backend default the parent's inherited config/backend names, so the spawn
  # writes FM_BACKEND=t3code into the mate thread's environment.
  if ! out=$(HERDR_SESSION="$REMOTE_HERDR_SESSION" FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_SKIP_SECONDMATE_SYNC=1 \
    FM_SPAWN_SECONDMATE_CREW_BACKEND="$([ "$selected_backend" != t3code ] || printf t3code)" \
    "$SCRIPT_DIR/fm-spawn.sh" "${ARGS[@]}" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die "remote host-local secondmate launch failed"
  fi
  [ -f "$meta" ] || die "remote launch returned without endpoint metadata"
  if [ "$selected_backend" = herdr ]; then
    herdr_session=$(fm_meta_get "$meta" herdr_session)
    [ "$herdr_session" = "$REMOTE_HERDR_SESSION" ] \
      || die "remote launch recorded Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'"
  else
    t3_host_attach "$id"
  fi
  print_route "$id"
}

# The home's own bin/fm-t3-host.sh, with the job's code-root overrides cleared
# so it resolves the home as its checkout, exactly as the mate thread does.
t3_host() { # <verb> [args...]
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_DATA_OVERRIDE='' \
    "$TARGET_HOME/bin/fm-t3-host.sh" "$@"
}

# Record the launched thread as the home's T3 host thread and (re)install the
# home's wake relay, which owns the mate's watcher outside the session and
# reopens an unloaded mate with each wake. A failure here leaves the endpoint
# launched but unsupervised across an idle unload, so it fails the launch for
# the parent to report rather than claiming a whole route.
t3_host_attach() { # <id>
  local id=$1
  remote_endpoint_require "$id"
  t3_host adopt --thread "$REMOTE_ENDPOINT_TARGET" >/dev/null \
    || die "remote secondmate $id launched as T3 thread $REMOTE_ENDPOINT_TARGET, but the home could not record it as its T3 host thread"
  t3_host install >/dev/null \
    || die "remote secondmate $id launched as T3 thread $REMOTE_ENDPOINT_TARGET, but its wake relay service could not be installed"
}

# A T3 launch writes the mate's environment into the home itself (the env block
# of .claude/settings.local.json, or the Codex overlay), because T3 sets no
# per-thread environment. An agent launched in the home on another endpoint
# would read it too - FM_BACKEND=t3code and a dead thread as its supervisor -
# so release removes exactly that and keeps every other local setting, and the
# home's T3 host record goes with the thread it named.
t3_env_remove() {
  local settings="$TARGET_HOME/.claude/settings.local.json"
  if [ -f "$settings" ]; then
    node -e '
const fs = require("fs");
const file = process.argv[1];
const data = JSON.parse(fs.readFileSync(file, "utf8"));
delete data.env;
if (Object.keys(data).length === 0) fs.unlinkSync(file);
else fs.writeFileSync(file, JSON.stringify(data) + "\n");
' "$settings" || return 1
  fi
  "$SCRIPT_DIR/fm-t3code-codex-env.sh" cleanup "$TARGET_HOME" || return 1
  rm -f "$TARGET_HOME/state/.t3-host"
}

# The T3 relay service a home installs is named for the home, so the code
# root's own copy can remove it even after retirement removed the home.
t3_relay_uninstall() {
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_DATA_OVERRIDE='' \
    "$SCRIPT_DIR/fm-t3-host.sh" uninstall >/dev/null 2>&1
}

# Restart the second-mate agent this host runs, by executing the ORDINARY local
# control plane here. From this host's point of view the mate is a plain local
# secondmate: its endpoint record under the private parent-route state directory
# was written by a host-local fm-spawn and carries no remote_host= field, so
# bin/fm-control.sh's remote refusal never fires, and every checkpoint, journal,
# rollback, and postcondition that plane owns applies unchanged. This verb is the
# transport hop, not a second implementation.
#
# harness/model/effort come from the PARENT and are passed explicitly, because
# config/secondmate-harness is deliberately not inherited into a secondmate home:
# the copy on this host is a different home's file, so letting the control plane
# re-resolve it here would silently drift the mate onto another runtime. `default`
# explicitly clears an absent parent pin; `-` remains its compatibility spelling.
cmd_relaunch() {
  local id=$1 harness=$2 model=$3 effort=$4
  local -a control_args

  validate_id "$id"
  validate_home "$id"
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *) die "unverified remote secondmate harness: $harness" ;;
  esac
  case "$effort" in -|default|low|medium|high|xhigh|max|ultra) ;; *) die "invalid remote secondmate effort: $effort" ;; esac
  case "$model" in *[[:space:]]*) die "invalid remote secondmate model: $model" ;; esac
  if [ "$effort" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
  fi
  remote_endpoint_require "$id"
  [ "$model" != - ] || model=default
  [ "$effort" != - ] || effort=default
  control_args=("$id" relaunch --harness "$harness" --model "$model" --effort "$effort")
  # The same launch-boundary facts cmd_launch establishes: the endpoint lives in
  # the dedicated fm-remote session, and the parent already owns both convergence
  # legs, so the host-local spawn must not re-sync or re-inherit against this
  # host's own Firstmate copy.
  HERDR_SESSION="$REMOTE_HERDR_SESSION" FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_SKIP_SECONDMATE_SYNC=1 \
    "$SCRIPT_DIR/fm-control.sh" "${control_args[@]}"
  # A parent tracking this route needs the identity the relaunch actually
  # produced, not the one it asked for, so it can republish its own record the
  # same way cmd_launch's caller already does. Reading it back from the
  # endpoint's own republished metadata - rather than trusting these argv
  # values - is what makes that record correct even when relaunch resolved
  # "default" against a configured pin this call never saw.
  print_route "$id"
}

cmd_send() {
  local id=$1 message=$2 delivery_mode=${3:-} rec ring_rc=0 meta meta_lock
  validate_id "$id"
  [ -z "$delivery_mode" ] || [ "$delivery_mode" = fire-and-forget ] || die "invalid send delivery mode"
  validate_home "$id"
  meta=$(meta_path "$id")
  meta_lock=$(fm_meta_lock_path "$meta") || die "remote secondmate metadata lock path is invalid"
  fm_task_inbox_lock_acquire "$meta_lock" \
    || die "remote secondmate endpoint metadata could not be locked for final delivery validation"
  if ! remote_endpoint_load "$id"; then
    fm_lock_release "$meta_lock"
    die "$REMOTE_ENDPOINT_ERROR"
  fi
  # A remote steer is delivered by durable record, never by submitting its payload
  # directly: write it into this secondmate's host-local steering inbox, then ring
  # the constant self-describing doorbell through the recorded backend endpoint,
  # best-effort (bin/fm-task-inbox-lib.sh owns the record and doorbell). The
  # write is idempotent - re-running the same request after an ambiguous
  # transport failure lands on the existing record instead of a duplicate - so
  # the parent may safely repeat this leg. Exit 0 once the record durably
  # exists; no ring outcome changes it, because the parent transport owns any
  # retry or reply-tracking policy from here.
  if ! rec=$(fm_task_inbox_write_idempotent "$CONTROL_STATE" "$id" "$message" "$delivery_mode"); then
    fm_lock_release "$meta_lock"
    die "steering-inbox record could not be written under $CONTROL_STATE/$id.inbox"
  fi
  fm_lock_release "$meta_lock"
  case "$rec" in
    */handled/*)
      # The dedup landed on a record the worker already acknowledged: the
      # steer was delivered and acted on, so there is nothing to announce.
      printf 'notice: this steer was already delivered and acknowledged at %s; nothing re-rung\n' "$rec" >&2
      return 0
      ;;
  esac
  # A T3 doorbell reopens a mate session T3 unloaded while idle, and a reopened
  # session runs no SessionStart hooks, so tell it first. Best-effort like the
  # ring itself: the record is already durable.
  if [ "$REMOTE_ENDPOINT_BACKEND" = t3code ] && ! fm_t3_session_holder_alive "$TARGET_HOME/state"; then
    fm_backend_send_text_submit "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" \
      "$FM_T3_REOPENED_SESSION_HINT" 2 0.4 0.3 "fm-$id" >/dev/null 2>&1 || true
  fi
  fm_task_inbox_ring "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$rec" "fm-$id" || ring_rc=$?
  case "$ring_rc" in
    1) printf 'notice: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at %s\n' "$rec" >&2 ;;
    2) printf 'notice: doorbell did not reach %s; the steer is durably recorded at %s\n' "$REMOTE_ENDPOINT_TARGET" "$rec" >&2 ;;
    3) printf 'notice: doorbell not typed because the agent in %s has exited; the steer is durably recorded at %s for recovery\n' "$REMOTE_ENDPOINT_TARGET" "$rec" >&2 ;;
  esac
}

cmd_key() {
  local id=$1 key=$2
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    "$SCRIPT_DIR/fm-send.sh" "$REMOTE_ENDPOINT_TARGET" --key "$key"
}

# The ordinary control plane's interrupt, run here where the endpoint lives:
# from this host the mate is a plain local secondmate (cmd_relaunch explains
# why), so the plane's own verification and verdict apply unchanged.
cmd_interrupt() {
  local id=$1
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" \
    "$SCRIPT_DIR/fm-control.sh" "$id" interrupt
}

# Close the recorded endpoint of an idle mate and set its record aside, so the
# next launch may use the other endpoint. Refused while the agent is busy or its
# state cannot be read, because closing it would cut a turn short; the home,
# its steering inbox, and its work are untouched, so a pending steer is read by
# whichever endpoint launches next.
cmd_release() {
  local id=$1 meta busy agent stamp
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  if [ ! -f "$meta" ] && [ ! -L "$meta" ]; then
    printf 'released: %s (no endpoint recorded)\n' "$id"
    return 0
  fi
  remote_endpoint_require "$id"
  agent=$(fm_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable')
  case "$agent" in
    alive)
      busy=$(fm_backend_busy_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unknown')
      [ "$busy" = idle ] || die "remote secondmate $id is $busy on $REMOTE_ENDPOINT_BACKEND; release it once its turn has ended"
      ;;
    dead|missing) ;;
    *) die "remote secondmate $id endpoint state is $agent; refusing to release an endpoint whose state cannot be read" ;;
  esac
  fm_backend_kill "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" \
    || die "remote secondmate $id endpoint $REMOTE_ENDPOINT_TARGET could not be closed on $REMOTE_ENDPOINT_BACKEND"
  if [ "$REMOTE_ENDPOINT_BACKEND" = t3code ]; then
    t3_relay_uninstall || true
    t3_env_remove || die "remote secondmate $id's T3 thread is archived, but its home still carries the T3 launch environment; remove the env block from $TARGET_HOME/.claude/settings.local.json and run $SCRIPT_DIR/fm-t3code-codex-env.sh cleanup $TARGET_HOME before launching it elsewhere"
  fi
  stamp=$(date +%s)
  mv -f -- "$meta" "$meta.released-$stamp" || die "could not set the released endpoint record aside"
  printf 'released: %s backend=%s target=%s record=%s\n' "$id" "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$meta.released-$stamp"
}

cmd_capture() {
  local id=$1 lines=${2:-20}
  validate_id "$id"
  validate_home "$id"
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le 100 ] || die "capture line count exceeds 100"
  remote_endpoint_require "$id"
  fm_backend_capture "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$lines" "fm-$id" | head -c 65536
}

cmd_observe() {
  local id=$1 harness
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  fm_pending_reply_backend_observation "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "fm-$id" "$harness"
  printf '\n'
}

# Make <commit> readable in this home's own object store without moving any other
# checkout. Ordered by cost: already present, then this host's Firstmate copy (a
# read-only fetch of that one commit, which never advances that copy's HEAD), then
# the home's own origin for that one commit. No pack transport beyond those two.
import_home_commit() { # <home> <commit>
  local home=$1 commit=$2
  if git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then return 0; fi
  if git -C "$home" fetch --quiet --no-tags -- "$FM_ROOT" "$commit" 2>/dev/null \
    && git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  if git -C "$home" remote get-url origin >/dev/null 2>&1 \
    && git -C "$home" fetch --quiet --no-tags -- origin "$commit" 2>/dev/null \
    && git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  return 1
}

cmd_sync() {
  local id=$1 commit report out
  validate_id "$id"
  validate_home "$id"
  if [ "$#" -ge 2 ]; then
    commit=$2
    case "$commit" in *[!0-9a-f]*) die "sync target must be a full 40-character commit id" ;; esac
    [ "${#commit}" -eq 40 ] || die "sync target must be a full 40-character commit id"
  else
    commit=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null) || die "remote code root HEAD is unreadable"
  fi
  import_home_commit "$TARGET_HOME" "$commit" \
    || die "remote home could not import $commit from this host's Firstmate copy or the home's origin; run /updatefirstmate to refresh this host's copy, or push that commit first"
  # ff_target publishes its verdict in FF_STATUS, so it must run in THIS shell.
  report=$(mktemp "${TMPDIR:-/tmp}/fm-remote-sync.XXXXXX") || die "cannot stage the sync report"
  ff_target "$TARGET_HOME" "remote home" "$commit" yes yes "$id" "$TARGET_HOME/state" > "$report" 2>&1
  out=$(cat "$report")
  rm -f "$report"
  case "$FF_STATUS" in
    # instr= names the watched instruction paths this advance changed, with no
    # spaces so the whole result stays one parseable line. The parent needs it to
    # decide whether the running agent must reload; an older parent ignores the
    # suffix, and an older HOST omits it, which a parent must read as unknown
    # rather than as "nothing changed".
    updated) printf 'synced: %s instr=%s\n' "$commit" "$(printf '%s' "$FF_INSTR" | tr -d ' ')" ;;
    current) printf 'current: %s\n' "$commit" ;;
    *) die "remote secondmate home sync skipped: ${out#remote home: skipped: }" ;;
  esac
}

cmd_update() {
  local id=$1 update_out root_status
  validate_id "$id"
  validate_home "$id"
  if ! update_out=$(FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-update.sh" 2>&1); then
    [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
    die "remote code root update failed"
  fi
  root_status=$(printf '%s\n' "$update_out" | grep '^firstmate:' | tail -1)
  case "$root_status" in
    'firstmate: updated '*|'firstmate: already current'*) ;;
    *)
      [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
      die "remote code root did not complete a safe origin update"
      ;;
  esac
  cmd_sync "$id"
}

cmd_retire() {
  local id=$1 force=${2:-} rc
  validate_id "$id"
  validate_home "$id" yes || rc=$?
  if [ "${rc:-0}" -eq 2 ]; then
    t3_relay_uninstall || true
    printf 'already-retired: %s\n' "$id"
    return 0
  fi
  [ -z "$force" ] || [ "$force" = --force ] || usage
  remote_endpoint_require "$id"
  retire_home "$id" "$force"
  # Teardown removed the home, so its relay has nothing left to supervise.
  [ "$REMOTE_ENDPOINT_BACKEND" != t3code ] || t3_relay_uninstall || true
}

retire_home() { # <id> [--force]
  local id=$1 force=${2:-}
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" "$SCRIPT_DIR/fm-guard.sh" || true
  if [ -n "$force" ]; then
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id" --force
  else
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id"
  fi
}

case "${1:-}" in
  launch) shift; [ "$#" -ge 5 ] && [ "$#" -le 6 ] || usage; cmd_launch "$@" ;;
  relaunch) shift; [ "$#" -eq 4 ] || usage; cmd_relaunch "$@" ;;
  state) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; validate_home "$1"; state_value "$1" ;;
  route) shift; [ "$#" -eq 1 ] || usage; cmd_route "$1" ;;
  send) shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_send "$@" ;;
  key) shift; [ "$#" -eq 2 ] || usage; cmd_key "$@" ;;
  interrupt) shift; [ "$#" -eq 1 ] || usage; cmd_interrupt "$1" ;;
  release) shift; [ "$#" -eq 1 ] || usage; cmd_release "$1" ;;
  capture) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_capture "$@" ;;
  observe) shift; [ "$#" -eq 1 ] || usage; cmd_observe "$@" ;;
  sync) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_sync "$@" ;;
  update) shift; [ "$#" -eq 1 ] || usage; cmd_update "$@" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
