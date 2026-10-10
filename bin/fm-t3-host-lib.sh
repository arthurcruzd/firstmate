# shellcheck shell=bash
# Shared predicates for a Firstmate home whose primary or second mate runs as a
# T3 Code thread.
# Usage: . bin/fm-t3-host-lib.sh
#
# bin/fm-t3-host.sh owns the relay and its record; this file answers whether
# a live relay owns the home's watcher, for the readers that must stand aside
# for it: the Claude Stop auto-arm (bin/fm-claude-stop-autoarm.sh), the
# Claude turn-end guard (bin/fm-turnend-guard.sh), and the supervision protocol
# renderer (bin/fm-supervision-instructions.sh). It also owns the two records
# the relay shares with the supervision host and the dialog mirror: the relay
# outbox and the relay's sent record (below).
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

# THE RELAY OUTBOX. On a home that runs the supervision host
# (bin/fm-supervision-host.sh, docs/supervision-host.md), the relay runs the
# host as its watcher cycle and the host never exits to hand main a close:
# it puts the text main must receive into state/.t3-relay-outbox, one file per
# close, and keeps supervising. The relay delivers each file to the primary
# thread in name order and removes it once T3 accepts it, so a close the relay
# has not yet delivered survives a relay restart. A file name is
# <epoch>-<host pid>-<seq>.close, so name order is arrival order; it is
# published by an atomic rename, so the relay never reads a partial file.
FM_T3_RELAY_OUTBOX_DIRNAME=.t3-relay-outbox

# fm_t3_relay_outbox_put <state-dir> <seq> <text>: publish one close; fails
# when it could not be written whole.
fm_t3_relay_outbox_put() {
  local dir="$1/$FM_T3_RELAY_OUTBOX_DIRNAME" name tmp
  name="$(date +%s)-$$-$(printf '%06d' "$2").close"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.put.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$3" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$dir/$name" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
}

# THE RELAY'S SENT RECORD. Every message the relay sends to the primary
# thread arrives there as a user prompt, which the Claude dialog-mirror writer
# (bin/fm-host-mirror.sh) would otherwise record as the captain's words. The
# relay keeps the newest FM_T3_RELAY_SENT_KEEP bodies it sent under
# state/.t3-relay-sent, and the writer drops a prompt whose text is exactly
# one of them (trailing whitespace aside).
FM_T3_RELAY_SENT_DIRNAME=.t3-relay-sent
FM_T3_RELAY_SENT_KEEP=50

# fm_t3_relay_sent_record <state-dir> <request-id> <file>
fm_t3_relay_sent_record() {
  local dir="$1/$FM_T3_RELAY_SENT_DIRNAME" tmp old
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.rec.XXXXXX" 2>/dev/null) || return 1
  cp "$3" "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$2.msg" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # shellcheck disable=SC2012 # Names are relay request ids: no newlines.
  ls -t "$dir" 2>/dev/null | sed -n "$((FM_T3_RELAY_SENT_KEEP + 1)),\$p" | while IFS= read -r old; do
    rm -f "$dir/$old"
  done
  return 0
}

# fm_t3_relay_sent_message <state-dir> <text>: 0 when <text> is a message the
# relay sent.
fm_t3_relay_sent_message() {
  local file body
  [ -d "$1/$FM_T3_RELAY_SENT_DIRNAME" ] || return 1
  for file in "$1/$FM_T3_RELAY_SENT_DIRNAME"/*.msg; do
    [ -f "$file" ] || continue
    body=$(cat "$file" 2>/dev/null) || continue
    body=${body%"${body##*[![:space:]]}"}
    [ "$body" = "$2" ] && return 0
  done
  return 1
}
