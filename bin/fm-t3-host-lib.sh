# shellcheck shell=bash
# Shared predicates for a Firstmate home whose primary or second mate runs as a
# T3 Code thread.
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

# A process's start identity. On Linux it is the kernel's start time in clock
# ticks since boot (/proc/<pid>/stat field 22), which never moves; `ps -o
# lstart` derives wall time from a boot time that drifts under WSL2 when the
# host clock is unsynchronized, which would make a live relay look replaced.
fm_t3_relay_proc_started() {  # <pid>
  local stat rest
  if [ -r "/proc/$1/stat" ] && stat=$(cat "/proc/$1/stat" 2>/dev/null) && [ -n "$stat" ]; then
    # The command name in field 2 may contain spaces, so count from its close.
    rest=${stat##*) }
    printf 'ticks:%s\n' "$(printf '%s' "$rest" | awk '{print $20}')"
    return 0
  fi
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
  # A relay started before the tick form existed recorded `ps -o lstart`, so
  # either spelling of the same live process still owns the home.
  [ "$(fm_t3_relay_proc_started "$pid")" = "$started" ] \
    || [ "$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')" = "$started" ] || return 1
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
  case "$cmd" in *fm-t3-host.sh*relay*) return 0 ;; esac
  return 1
}

# A T3 session that T3 reopened after unloading the idle one runs none of its
# SessionStart hooks, so its session lock (state/.lock) still names the process
# that ran session start. bin/fm-t3-host.sh's relay and the T3 doorbell in
# bin/fm-remote-secondmate-control.sh both add this hint to the message that
# reopens such a session.
# shellcheck disable=SC2034 # Consumed by the sourcing callers.
FM_T3_REOPENED_SESSION_HINT='Your session was reopened by T3 after it unloaded the idle one, so the session lock still names the dead process: run bin/fm-session-start.sh first, then continue.'

# fm_t3_session_holder_alive <state-dir>
# Exit 0 when the session lock names a live process.
fm_t3_session_holder_alive() {
  local pid
  pid=$(head -1 "$1/.lock" 2>/dev/null | tr -dc '0-9')
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
