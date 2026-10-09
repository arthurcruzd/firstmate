#!/usr/bin/env bash
# Move a REMOTE secondmate's agent between the two runtimes its host can run it
# on - Herdr's fm-remote session and that host's own T3 Code server - and back.
#
# Usage: fm-remote-secondmate-move.sh <id> <herdr|t3code> [--harness <h>] [--model <m>] [--effort <e>]
#
# The route's registry endpoint (data/secondmates.md, `endpoint:` after
# `root:`, absent meaning herdr) is what every launch and recovery reads, so a
# move is: check the host is ready for the target endpoint, rewrite that one
# field, release the old endpoint on the host, and launch through the ordinary
# bin/fm-spawn.sh <id> --secondmate path. Moving back is the same command with
# the other endpoint.
#
# Only the agent moves. The remote home, its backlog, projects, workers, the
# parent channel, and the steering inbox stay where they are, so a steer that
# was waiting is read by the new endpoint, a correlated reply still settles,
# and the mate's own workers keep the backend their records name.
#
# Safety:
#   - The read-only readiness check for the target endpoint runs before
#     anything changes; a gap refuses with the doctor's own text.
#   - The host releases only an idle endpoint (bin/fm-remote-secondmate-
#     control.sh release), so a turn is never cut short; a refusal restores the
#     registry and leaves the old endpoint running.
#   - The move holds the mate's liveness lock, so the watcher's recovery tick
#     cannot relaunch the old endpoint between the release and the launch.
#   - SSH exit 255 means unknown remote completion: the registry keeps the
#     target endpoint, the move stops, and the operator reconciles on the host
#     before rerunning the same command, which converges.
# Optional --harness, --model, and --effort pass through to the launch; the
# defaults are the ordinary secondmate pin (config/secondmate-harness). A T3
# endpoint runs only claude or codex, with a model slug from that server's
# catalog.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -ge 2 ] || usage
ID=$1
TARGET=$2
shift 2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$TARGET" in herdr|t3code) ;; *) die "unknown remote secondmate endpoint: $TARGET" ;; esac
LAUNCH_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness|--model|--effort)
      [ "$#" -ge 2 ] || usage
      LAUNCH_ARGS+=("$1" "$2")
      shift 2
      ;;
    *) usage ;;
  esac
done

LIVE_LOCK_HELD=0
REGISTRY_LOCK=
REGISTRY_LOCK_HELD=0
cleanup() {
  [ "$REGISTRY_LOCK_HELD" -eq 0 ] || fm_lock_release "$REGISTRY_LOCK" || true
  [ "$LIVE_LOCK_HELD" -eq 0 ] || fm_secondmate_liveness_unlock "$ID"
}
trap cleanup EXIT

[ "$(secondmate_registry_field "$REG" "$ID" remote 2>/dev/null)" = 1 ] \
  || die "$ID is not a remote secondmate route in $REG"
CURRENT=$(secondmate_registry_field "$REG" "$ID" endpoint)

# The watcher's liveness tick takes this lock before it acts on a dead or
# missing endpoint, so holding it keeps recovery from racing the move.
mkdir -p "$STATE"
tries=0
until fm_secondmate_liveness_lock "$ID"; do
  tries=$((tries + 1))
  [ "$tries" -lt 60 ] || die "the liveness lock for $ID stayed busy for a minute; retry the move"
  sleep 1
done
LIVE_LOCK_HELD=1

doctor_args=()
[ "$TARGET" != t3code ] || doctor_args=(--endpoint t3code)
rc=0
out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-doctor.sh ${doctor_args[@]+"${doctor_args[@]}"} </dev/null 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  [ "$rc" -ne 255 ] || die "the host for $ID could not be reached; nothing was changed"
  die "the host for $ID is not ready for the $TARGET endpoint; nothing was changed"
fi

# rewrite_endpoint <endpoint>: replace the route's endpoint field in place,
# under the registry lock, and prove the rewritten record parses to exactly the
# same route with the new endpoint.
rewrite_endpoint() {
  local want=$1 line prefix suffix next tmp host root home
  local re='^(.*\(host:[[:space:]]*[^;)]*;[[:space:]]*root:[[:space:]]*[^;)]*)(;[[:space:]]*endpoint:[[:space:]]*(herdr|t3code))?(;[[:space:]]*home:.*)$'
  REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$REGISTRY_LOCK" || die "cannot lock the secondmate registry"
  REGISTRY_LOCK_HELD=1
  secondmate_registry_line_for_id "$REG" "$ID" || die "cannot read the registry record for $ID"
  line=$SECONDMATE_REGISTRY_LINE
  host=$SECONDMATE_REGISTRY_HOST root=$SECONDMATE_REGISTRY_ROOT home=$SECONDMATE_REGISTRY_HOME
  [[ "$line" =~ $re ]] || die "cannot locate the route fields in the registry record for $ID"
  prefix=${BASH_REMATCH[1]}
  suffix=${BASH_REMATCH[4]}
  if [ "$want" = t3code ]; then next="$prefix; endpoint: t3code$suffix"; else next="$prefix$suffix"; fi
  secondmate_registry_parse_line "$next" \
    && [ "$SECONDMATE_REGISTRY_ENDPOINT" = "$want" ] && [ "$SECONDMATE_REGISTRY_HOST" = "$host" ] \
    && [ "$SECONDMATE_REGISTRY_ROOT" = "$root" ] && [ "$SECONDMATE_REGISTRY_HOME" = "$home" ] \
    || die "the rewritten registry record for $ID would not parse to the same route"
  tmp="$REG.move.$$"
  while IFS= read -r l || [ -n "$l" ]; do
    if [ "$l" = "$line" ]; then printf '%s\n' "$next"; else printf '%s\n' "$l"; fi
  done < "$REG" > "$tmp"
  mv -f -- "$tmp" "$REG"
  fm_lock_release "$REGISTRY_LOCK"
  REGISTRY_LOCK_HELD=0
}

if [ "$CURRENT" != "$TARGET" ]; then
  rewrite_endpoint "$TARGET"
  printf 'registry: %s endpoint %s -> %s\n' "$ID" "$CURRENT" "$TARGET"
fi

rc=0
out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh route "$ID" </dev/null 2>/dev/null) || rc=$?
recorded=$(printf '%s\n' "$out" | sed -n 's/^backend=//p' | tail -1)
if [ "$rc" -eq 0 ] && [ -n "$recorded" ] && [ "$recorded" != "$TARGET" ]; then
  rc=0
  out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh release "$ID" </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    if [ "$rc" -eq 255 ]; then
      die "releasing $ID's $recorded endpoint has unknown completion; reconcile it on the host, then rerun this command"
    fi
    [ "$CURRENT" = "$TARGET" ] || rewrite_endpoint "$CURRENT"
    die "the host did not release $ID's $recorded endpoint; the registry is restored and the mate keeps running there"
  fi
  printf '%s\n' "$out"
elif [ "$rc" -eq 255 ]; then
  die "the host for $ID could not be reached to read its endpoint; the registry names $TARGET, rerun this command to converge"
fi

rc=0
"$SCRIPT_DIR/fm-spawn.sh" "$ID" --secondmate ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"} || rc=$?
if [ "$rc" -ne 0 ]; then
  die "launching $ID on $TARGET failed (exit $rc); the registry names $TARGET, so rerun this command after fixing the cause, or move it back with: $0 $ID $CURRENT"
fi
printf 'moved: %s endpoint=%s (back: %s %s %s)\n' "$ID" "$TARGET" "$0" "$ID" "$CURRENT"
