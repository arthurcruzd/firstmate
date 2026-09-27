#!/usr/bin/env bash
# fm-herdr-pins.sh - keep the agents the captain talks to pinned in Herdr's
# sidebar Agents panel.
#
# Usage:
#   fm-herdr-pins.sh sync [<id>]
#   fm-herdr-pins.sh clear <id>
#   fm-herdr-pins.sh check
#   fm-herdr-pins.sh tag <session> <pane> <rank> <host> <label>
#   fm-herdr-pins.sh untag <session> <pane>
#   fm-herdr-pins.sh view <session> [set|clear]
#
# Herdr has no native pin. Each pinned agent's pane instead carries three
# display tokens reported under source `firstmate-pins` (pin_rank, pin_label,
# pin_host), and every server that hosts one carries a static agent view
# (source `firstmate:pins`, label "Pinned") that shows only panes with a
# pin_rank token, sorted by it. Herdr keeps neither across a server restart,
# and a relaunch can land an agent in a new pane, so Firstmate re-applies both
# at secondmate launch and relaunch, at primary session start, and on the
# secondmate liveness tick. docs/configuration.md "Pinned Herdr agents" owns
# the config/pinned-agents schema and the operator-facing behavior.
#
# sync applies every config entry this home owns, or only <id>'s. It resolves
# each agent's CURRENT pane from its recorded endpoint, never from a stored
# pane id: `self` is this firstmate's own supervisor pane
# (bin/fm-supervisor-target-lib.sh), a local secondmate is its validated
# state/<id>.meta endpoint, and a remote secondmate is tagged on its own host
# through `fm-remote-secondmate-control.sh pin`, which reads that host's
# endpoint record and installs the view on its fm-remote server. A full sync
# (no <id>) also clears the tokens of any agent the previous full sync pinned
# that the config no longer lists, and when the config lists nothing (or is
# gone) it also clears the view it installed, so removing the file undoes the
# feature. state/.herdr-pins-applied records what the last full sync applied
# (`pin <id>` and `view <session>` lines) for exactly that cleanup.
#
# clear removes <id>'s tokens (secondmate retirement calls it) and drops it
# from that record.
#
# check validates the config, prints each accepted entry as
# `<rank>\t<id>\t<host>\t<label>`, and exits 1 when any line was rejected.
#
# tag, untag, and view are the host-local primitives: they act on one exact
# pane or session of the local Herdr server and exit non-zero when Herdr does
# not confirm. bin/fm-remote-secondmate-control.sh's pin and unpin verbs use
# them on a remote secondmate's host.
#
# Best effort by contract: sync and clear always exit 0, print one line per
# entry (`pinned`, `cleared`, or `skipped <id>: <reason>`), and are silent
# no-ops when neither config/pinned-agents nor the applied record exists, when
# an agent is not on Herdr, or when Herdr (or python3, for the view) is
# missing or unreachable. Callers discard the output and never fail a spawn,
# relaunch, retirement, or liveness pass on it.
#
# Environment:
#   FM_HERDR_PINS_CALL_TIMEOUT   seconds per local Herdr call (default 10)
#   FM_HERDR_PINS_REMOTE_TIMEOUT seconds per remote pin/unpin call (default 45)
#   FM_HERDR_PINS_VIEW_SETTER    view transport (default
#                                bin/backends/herdr-agent-view.py)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PINS_CONFIG="$CONFIG/pinned-agents"
PINS_APPLIED="$STATE/.herdr-pins-applied"
PIN_SOURCE=firstmate-pins

usage() { sed -n '5,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

CMD=${1:-}
case "$CMD" in
  sync|clear)
    # The off path costs two file tests and sources nothing.
    [ -f "$PINS_CONFIG" ] || [ -f "$PINS_APPLIED" ] || exit 0
    ;;
  check|tag|untag|view) ;;
  *) usage ;;
esac

CALL_TIMEOUT=${FM_HERDR_PINS_CALL_TIMEOUT:-}
case "$CALL_TIMEOUT" in ''|*[!0-9]*|0) CALL_TIMEOUT=10 ;; esac
REMOTE_TIMEOUT=${FM_HERDR_PINS_REMOTE_TIMEOUT:-}
case "$REMOTE_TIMEOUT" in ''|*[!0-9]*|0) REMOTE_TIMEOUT=45 ;; esac
VIEW_SETTER=${FM_HERDR_PINS_VIEW_SETTER:-$SCRIPT_DIR/backends/herdr-agent-view.py}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

valid_rank() { case "$1" in [0-9][0-9]) [ "$1" != 00 ] ;; *) return 1 ;; esac; }
valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
valid_host() {
  case "$1" in ''|*[!A-Za-z0-9._@-]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}
valid_label() {
  case "$1" in ''|*[[:cntrl:]]*) return 1 ;; esac
  [ "${#1}" -le 48 ]
}

# --- config ------------------------------------------------------------------

# pins_parse: accepted entries as `<rank>\t<id>\t<host>\t<label>` on stdout,
# one rejection per line on stderr; fails when any line was rejected. A later
# line for an id already accepted is rejected rather than silently winning.
pins_parse() {
  local line n=0 bad=0 rank id host label seen='|'
  [ -f "$PINS_CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    read -r rank id host label <<< "$line"
    case "$rank" in ''|'#'*) continue ;; esac
    case "$rank" in
      [0-9]|[0-9][0-9]) rank=$(printf '%02d' "$((10#$rank))") ;;
      *) rank=bad ;;
    esac
    if ! valid_rank "$rank" || ! valid_id "$id" || ! valid_host "$host" || ! valid_label "$label"; then
      printf 'pinned-agents line %s: expected <rank 1-99> <self|secondmate-id> <host|-> <label>\n' "$n" >&2
      bad=1
      continue
    fi
    case "$seen" in
      *"|$id|"*)
        printf 'pinned-agents line %s: %s is already pinned by an earlier line\n' "$n" "$id" >&2
        bad=1
        continue
        ;;
    esac
    seen="$seen$id|"
    printf '%s\t%s\t%s\t%s\n' "$rank" "$id" "$host" "$label"
  done < "$PINS_CONFIG"
  [ "$bad" -eq 0 ]
}

# --- host-local Herdr primitives ---------------------------------------------

pins_herdr() {  # <session> <herdr-args...>
  local session=$1
  shift
  command -v herdr >/dev/null 2>&1 || return 127
  fm_backend_source herdr >/dev/null 2>&1 || return 1
  fm_backend_herdr_client_select "$session" >/dev/null 2>&1
  HERDR_SESSION="$session" fm_run_timed "$CALL_TIMEOUT" "$(fm_backend_herdr_bin)" "$@" --session "$session" </dev/null >/dev/null 2>&1
}

pins_tag() {  # <session> <pane> <rank> <host> <label>
  pins_herdr "$1" pane report-metadata "$2" --source "$PIN_SOURCE" \
    --token "pin_rank=$3" --token "pin_label=$5" --token "pin_host=$4"
}

pins_untag() {  # <session> <pane>
  pins_herdr "$1" pane report-metadata "$2" --source "$PIN_SOURCE" \
    --clear-token pin_rank --clear-token pin_label --clear-token pin_host
}

pins_view() {  # <session> <set|clear>
  local session=$1 action=$2 sock
  command -v herdr >/dev/null 2>&1 || return 127
  [ -n "${FM_HERDR_PINS_VIEW_SETTER:-}" ] || command -v python3 >/dev/null 2>&1 || return 127
  fm_backend_source herdr >/dev/null 2>&1 || return 1
  sock=$(fm_backend_herdr_socket_path "$session")
  [ -n "$sock" ] || return 1
  fm_run_timed "$CALL_TIMEOUT" "$VIEW_SETTER" "$sock" "$action" </dev/null >/dev/null 2>&1
}

# --- endpoint resolution -----------------------------------------------------

# pins_resolve <id>: sets PIN_KIND (local|remote|skip), PIN_SESSION, PIN_PANE,
# PIN_DEFAULT_HOST, and PIN_REASON on skip. Every value is read from the
# endpoint's current record, so a relaunch into a new pane is followed.
pins_resolve() {
  local id=$1 meta backend target remote_host
  PIN_KIND=skip PIN_SESSION='' PIN_PANE='' PIN_DEFAULT_HOST='' PIN_REASON=''
  if [ "$id" = self ]; then
    backend=$(discover_supervisor_backend) || { PIN_REASON="no supervisor pane detected"; return 0; }
    [ "$backend" = herdr ] || { PIN_REASON="supervisor pane is on $backend, not herdr"; return 0; }
    target=$(discover_supervisor_target) || { PIN_REASON="no supervisor pane detected"; return 0; }
  else
    meta="$STATE/$id.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || { PIN_REASON="no endpoint record"; return 0; }
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] || { PIN_REASON="not a secondmate"; return 0; }
    remote_host=$(fm_meta_get "$meta" remote_host)
    if [ -n "$remote_host" ]; then
      PIN_KIND=remote
      PIN_DEFAULT_HOST=$remote_host
      return 0
    fi
    fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 \
      || { PIN_REASON="endpoint record does not validate"; return 0; }
    [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] \
      || { PIN_REASON="endpoint is on $FM_BACKEND_VALIDATED_BACKEND, not herdr"; return 0; }
    target=$FM_BACKEND_VALIDATED_TARGET
  fi
  PIN_SESSION=${target%%:*}
  PIN_PANE=${target#*:}
  if [ -z "$PIN_SESSION" ] || [ -z "$PIN_PANE" ] || [ "$PIN_PANE" = "$target" ]; then
    PIN_REASON="endpoint target '$target' is not a herdr pane"
    return 0
  fi
  PIN_KIND=local
  PIN_DEFAULT_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
  valid_host "$PIN_DEFAULT_HOST" || PIN_DEFAULT_HOST=local
}

pins_remote() {  # <id> <control-verb-args...>
  local id=$1
  shift
  fm_run_timed "$REMOTE_TIMEOUT" "$SCRIPT_DIR/fm-on.sh" "$id" \
    fm-remote-secondmate-control.sh "$@" </dev/null >/dev/null 2>&1
}

# --- applied record ----------------------------------------------------------

applied_list() {  # <pin|view>
  [ -f "$PINS_APPLIED" ] || return 0
  awk -v kind="$1" '$1 == kind && NF == 2 { print $2 }' "$PINS_APPLIED" 2>/dev/null
}

applied_write() {  # <pin-ids-lines> <view-sessions-lines>
  local tmp
  if [ -z "$1" ] && [ -z "$2" ]; then
    rm -f "$PINS_APPLIED"
    return 0
  fi
  [ -d "$STATE" ] || return 0
  tmp=$(mktemp "$STATE/.herdr-pins-applied.XXXXXX") || return 0
  {
    [ -z "$1" ] || printf '%s\n' "$1" | awk 'NF { print "pin " $1 }'
    [ -z "$2" ] || printf '%s\n' "$2" | awk 'NF { print "view " $1 }'
  } > "$tmp"
  mv -f -- "$tmp" "$PINS_APPLIED" || rm -f "$tmp"
}

lines_has() { printf '%s\n' "$1" | grep -Fx -- "$2" >/dev/null 2>&1; }
lines_add() { if lines_has "$1" "$2"; then printf '%s' "$1"; else printf '%s%s%s' "$1" "${1:+$'\n'}" "$2"; fi; }

# --- verbs -------------------------------------------------------------------

# pins_clear_one <id> [view]: clear <id>'s tokens; `view` also asks a remote
# host to clear its view (used only when nothing stays pinned). Fails when the
# clear was attempted and not confirmed.
pins_clear_one() {
  local id=$1 with_view=${2:-}
  pins_resolve "$id"
  case "$PIN_KIND" in
    local) pins_untag "$PIN_SESSION" "$PIN_PANE" || return 1 ;;
    remote)
      if [ -n "$with_view" ]; then
        pins_remote "$id" unpin "$id" --view || return 1
      else
        pins_remote "$id" unpin "$id" || return 1
      fi
      ;;
    *) printf 'skipped %s: %s\n' "$id" "$PIN_REASON"; return 0 ;;
  esac
  printf 'cleared %s\n' "$id"
}

cmd_sync() {
  local only=${1:-} entries rank id host label pinned='' views='' prev_pins prev_views keep=''
  if [ -n "$only" ]; then
    valid_id "$only" || usage
  fi
  entries=$(pins_parse 2>/dev/null) || true
  while IFS=$'\t' read -r rank id host label; do
    [ -n "$id" ] || continue
    [ -z "$only" ] || [ "$id" = "$only" ] || continue
    pinned=$(lines_add "$pinned" "$id")
    pins_resolve "$id"
    [ "$host" != - ] || host=$PIN_DEFAULT_HOST
    case "$PIN_KIND" in
      local)
        if pins_tag "$PIN_SESSION" "$PIN_PANE" "$rank" "$host" "$label"; then
          printf 'pinned %s %s:%s\n' "$id" "$PIN_SESSION" "$PIN_PANE"
        else
          printf 'skipped %s: herdr did not confirm the tokens\n' "$id"
        fi
        if ! lines_has "$views" "$PIN_SESSION"; then
          pins_view "$PIN_SESSION" set || printf 'skipped view %s: herdr did not confirm the view\n' "$PIN_SESSION"
          views=$(lines_add "$views" "$PIN_SESSION")
        fi
        ;;
      remote)
        if pins_remote "$id" pin "$id" "$rank" "$host" "$label"; then
          printf 'pinned %s remote\n' "$id"
        else
          printf 'skipped %s: remote pin did not complete\n' "$id"
        fi
        ;;
      *) printf 'skipped %s: %s\n' "$id" "$PIN_REASON" ;;
    esac
  done <<< "$entries"
  [ -z "$only" ] || return 0

  # A full sync reconciles what the previous one applied.
  prev_pins=$(applied_list pin)
  prev_views=$(applied_list view)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    lines_has "$pinned" "$id" && continue
    if [ -z "$pinned" ]; then
      pins_clear_one "$id" view || keep=$(lines_add "$keep" "$id")
    else
      pins_clear_one "$id" || keep=$(lines_add "$keep" "$id")
    fi
  done <<< "$prev_pins"
  if [ -z "$pinned" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      pins_view "$id" clear || true
    done <<< "$prev_views"
  else
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      views=$(lines_add "$views" "$id")
    done <<< "$prev_views"
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    pinned=$(lines_add "$pinned" "$id")
  done <<< "$keep"
  applied_write "$pinned" "$views"
}

cmd_clear() {
  local id=$1 rest=''
  valid_id "$id" || usage
  pins_clear_one "$id" || true
  if lines_has "$(applied_list pin)" "$id"; then
    rest=$(applied_list pin | grep -Fvx -- "$id" || true)
    applied_write "$rest" "$(applied_list view)"
  fi
}

case "$CMD" in
  sync) [ "$#" -le 2 ] || usage; cmd_sync "${2:-}"; exit 0 ;;
  clear) [ "$#" -eq 2 ] || usage; cmd_clear "$2"; exit 0 ;;
  check)
    [ "$#" -eq 1 ] || usage
    [ -f "$PINS_CONFIG" ] || { echo "no $PINS_CONFIG; herdr pins are off" >&2; exit 0; }
    pins_parse
    ;;
  tag)
    [ "$#" -eq 6 ] || usage
    if ! valid_id "$2" || [ -z "$3" ] || ! valid_rank "$4" || ! valid_host "$5" || ! valid_label "$6"; then
      usage
    fi
    pins_tag "$2" "$3" "$4" "$5" "$6"
    ;;
  untag)
    [ "$#" -eq 3 ] || usage
    if ! valid_id "$2" || [ -z "$3" ]; then usage; fi
    pins_untag "$2" "$3"
    ;;
  view)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
    valid_id "$2" || usage
    case "${3:-set}" in set|clear) ;; *) usage ;; esac
    pins_view "$2" "${3:-set}"
    ;;
esac
