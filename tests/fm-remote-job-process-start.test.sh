#!/usr/bin/env bash
# Process-start identity for the remote job runner.
# On a Linux-compatible /proc, fm_remote_job_process_start uses starttime ticks
# so a changing ps lstart for the same live pid cannot break the owner match.
# Elsewhere it keeps ps -o lstart=. An older lstart recording mismatches the
# tick identity and is treated as any other non-matching owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-job-process-start)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$ACCOUNT_HOME"
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

write_fake_proc_stat() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" \
    > "$proc_root/$pid/stat"
}

write_lock_owner() {
  local lock pid start command
  fm_remote_job_prepare_state "$ACCOUNT_HOME" || fail "could not prepare remote job state"
  lock=$(fm_remote_job_worker_lock_path)
  mkdir -p "$lock"
  pid=$1
  start=$2
  command=$3
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$start" > "$lock/start"
  printf '%s\n' "$command" > "$lock/command"
}

test_fake_proc_starttime_ignores_ps_lstart_and_parses_comm_safely() {
  local proc_root pid first second
  proc_root="$TMP_ROOT/proc-comm"
  pid=4242
  write_fake_proc_stat "$proc_root" "$pid" 987654
  first=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start "$pid") \
    || fail "could not read fake /proc starttime"
  [ "$first" = 987654 ] || fail "starttime with spaces/parens in comm was '$first', want 987654"
  write_fake_proc_stat "$proc_root" "$pid" 987654
  second=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start "$pid") \
    || fail "could not re-read fake /proc starttime"
  [ "$second" = "$first" ] || fail "fake /proc starttime changed without a tick change"
  write_fake_proc_stat "$proc_root" "$pid" 987655
  second=$(FM_PROC_ROOT_OVERRIDE="$proc_root" fm_remote_job_process_start "$pid") \
    || fail "could not read reused fake /proc pid"
  [ "$second" = 987655 ] || fail "changed starttime was not detected (got '$second')"
  pass "fake /proc starttime parses after the last ) and ignores a would-be ps lstart"
}

test_linux_live_pid_owner_match_survives_changed_ps_lstart() {
  local live first second lstart command
  case "$(uname -s)" in
    Linux) ;;
    *)
      pass "live Linux owner-match regression skipped on $(uname -s)"
      return
      ;;
  esac
  sleep 30 &
  live=$!
  first=$(fm_remote_job_process_start "$live") \
    || { kill "$live" 2>/dev/null || true; fail "could not read live process start identity"; }
  case "$first" in
    ''|*[!0-9]*)
      kill "$live" 2>/dev/null || true
      fail "Linux start identity was not starttime ticks ('$first')"
      ;;
  esac
  lstart=$( { [ -x /bin/ps ] && /bin/ps -p "$live" -o lstart= || /usr/bin/ps -p "$live" -o lstart=; } 2>/dev/null || true)
  [ -n "$lstart" ] || { kill "$live" 2>/dev/null || true; fail "could not read ps lstart for the live pid"; }
  [ "$first" != "$lstart" ] \
    || { kill "$live" 2>/dev/null || true; fail "Linux start identity still equals ps lstart ('$first')"; }
  second=$(fm_remote_job_process_start "$live") \
    || { kill "$live" 2>/dev/null || true; fail "could not re-read live process start identity"; }
  [ "$second" = "$first" ] \
    || { kill "$live" 2>/dev/null || true; fail "live start identity drifted ('$first' then '$second')"; }
  command=$(fm_remote_job_process_command "$live") \
    || { kill "$live" 2>/dev/null || true; fail "could not read live process command"; }
  write_lock_owner "$live" "$first" "$command"
  fm_remote_job_lock_owner_matches_process "$ACCOUNT_HOME" \
    || { kill "$live" 2>/dev/null || true; fail "owner match failed for a live pid whose ps lstart differs from starttime"; }
  write_lock_owner "$live" "$lstart" "$command"
  if fm_remote_job_lock_owner_matches_process "$ACCOUNT_HOME"; then
    kill "$live" 2>/dev/null || true
    fail "an older lstart recording still matched the live pid instead of recovering as a non-matching owner"
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "changed ps lstart for the same live pid no longer breaks the Linux owner match"
}

test_fake_proc_starttime_ignores_ps_lstart_and_parses_comm_safely
test_linux_live_pid_owner_match_survives_changed_ps_lstart

echo "ALL TESTS PASSED"
