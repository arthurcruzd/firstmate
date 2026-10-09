# shellcheck shell=bash
# Shared predicate for a Firstmate home whose primary runs as a T3 Code thread.
# Usage: . bin/fm-t3-host-lib.sh
#
# bin/fm-t3-host.sh owns the relay and its record; this file only answers
# whether a live relay owns the home's watcher, for the readers that must stand
# aside for it: the Claude Stop auto-arm (bin/fm-claude-stop-autoarm.sh), the
# Claude turn-end guard (bin/fm-turnend-guard.sh), and the supervision protocol
# renderer (bin/fm-supervision-instructions.sh).
#
# The record state/.t3-relay holds pid=<pid> and started=<process start>; it
# owns the home only while that pid is alive, is still the same process (its
# start stamp matches, so a reused pid never counts), and runs fm-t3-host.sh
# relay.

fm_t3_relay_proc_started() {  # <pid>
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'
}

# fm_t3_relay_owns_home <state-dir>
# Exit 0 exactly when a live, identity-matched wake relay owns this home.
fm_t3_relay_owns_home() {
  local state=$1 record pid started cmd
  record="$state/.t3-relay"
  [ -f "$record" ] || return 1
  pid=$(sed -n 's/^pid=//p' "$record" 2>/dev/null | head -1)
  started=$(sed -n 's/^started=//p' "$record" 2>/dev/null | head -1)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$started" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(fm_t3_relay_proc_started "$pid")" = "$started" ] || return 1
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
  case "$cmd" in *fm-t3-host.sh*relay*) return 0 ;; esac
  return 1
}
