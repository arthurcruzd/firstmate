#!/bin/bash
set -eu
LAB="$PWD/.test-remote-identity/identity"
mkdir -p "$LAB/account"
export FM_REMOTE_JOB_STATE_ROOT="$LAB/state"
. bin/fm-remote-job-lib.sh
python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(15,b"watch ) ( odd",0,0,0); time.sleep(90)' &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
sleep 0.2
start=$(fm_remote_job_process_start "$pid")
expected=$(python3 -c 'import sys; print(open("/proc/"+sys.argv[1]+"/stat").read().rsplit(")",1)[1].split()[19])' "$pid")
[ "$start" = "$expected" ]
printf 'Live process comm=%s; identity=%s; kernel field 22=%s\n' "$(cat "/proc/$pid/comm")" "$start" "$expected"
fm_remote_job_prepare_state "$LAB/account"
lock=$(fm_remote_job_worker_lock_path)
mkdir -p "$lock"
printf '%s\n' "$pid" > "$lock/pid"
printf '%s\n' "$start" > "$lock/start"
fm_remote_job_process_command "$pid" > "$lock/command"
fm_remote_job_lock_owner_matches_process "$LAB/account"
printf 'Real process ownership accepted with matching ticks\n'
printf '%s\n' "$((start+1))" > "$lock/start"
if fm_remote_job_lock_owner_matches_process "$LAB/account"; then exit 1; fi
printf 'Different ticks rejected for same live pid\n'
export FM_PROC_ROOT_OVERRIDE="$LAB/absent-proc"
lstart=$(fm_remote_job_process_start "$pid")
printf '%s\n' "$lstart" > "$lock/start"
fm_remote_job_lock_owner_matches_process "$LAB/account"
printf 'No-proc fallback accepted real ps identity: %s\n' "$lstart"
printf 'Mon Jan  1 00:00:00 2001\n' > "$lock/start"
rc=0
fm_remote_job_lock_owner_matches_process "$LAB/account" || rc=$?
[ "$rc" = 1 ]
printf 'No-proc stale lstart rejected with ordinary status=%s\n' "$rc"
