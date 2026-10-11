#!/bin/bash
set -eu
LAB="$PWD/.test-remote-identity/unrelated"
mkdir -p "$LAB/account"
export FM_REMOTE_JOB_STATE_ROOT="$LAB/state"
unset FM_PROC_ROOT_OVERRIDE FM_ROOT_OVERRIDE FM_REMOTE_JOB_PLATFORM_OVERRIDE
. bin/fm-remote-job-lib.sh
sleep 90 &
unrelated=$!
cleanup() {
  for p in $(jobs -pr); do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true; done
  wait || true
}
trap cleanup EXIT
fm_remote_job_prepare_state "$LAB/account"
lock=$(fm_remote_job_worker_lock_path)
mkdir -p "$lock"
printf '%s\n' "$unrelated" > "$lock/pid"
printf 'Mon Jan  1 00:00:00 2001\n' > "$lock/start"
fm_remote_job_process_command "$unrelated" > "$lock/command"
fm_remote_job_ensure_worker "$PWD/.test-remote-identity/live/root" "$LAB/account"
kill -0 "$unrelated"
printf 'Unrelated process pid=%s survived legacy-lock recovery\n' "$unrelated"
worker=$(cat "$lock/pid")
[ "$worker" != "$unrelated" ]
printf 'Ready worker pid=%s tick identity=%s\n' "$worker" "$(cat "$lock/start")"
fm_remote_job_stop_worker_tree "$worker"
