#!/bin/bash
set -eu
ROOT=$PWD
LAB="$ROOT/.test-tmp/live-runner"
mkdir -p "$LAB/account"
export FM_REMOTE_JOB_STATE_ROOT="$LAB/state"
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
  local pid
  for pid in $(jobs -pr); do
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT
unset FM_PROC_ROOT_OVERRIDE FM_REMOTE_JOB_PLATFORM_OVERRIDE FM_REMOTE_JOB_ACTIVE
for drift in 0 27; do
  fixture="$LAB/upgrade-$drift"
  mkdir -p "$fixture/bin" "$fixture/account"
  cp "$ROOT/AGENTS.md" "$fixture/AGENTS.md"
  for file in fm-remote-job-lib.sh fm-remote-job-worker.sh; do
    git show "9296f9b9d2566797b9a9aecaa5956bb8e471d2cd:bin/$file" > "$fixture/bin/$file"
    chmod +x "$fixture/bin/$file"
  done
  export FM_REMOTE_JOB_STATE_ROOT="$fixture/state"
  fm_remote_job_ensure_worker "$fixture" "$fixture/account"
  lock=$(fm_remote_job_worker_lock_path)
  old=$(cat "$lock/pid")
  old_group=$(fm_remote_job_process_pgid "$old")
  start=$(cat "$lock/start")
  printf 'BASE worker: pid=%s group=%s identity=%s\n' "$old" "$old_group" "$start"
  if [ "$drift" != 0 ]; then
    date -d "$start 27 seconds ago" '+%a %b %e %T %Y' > "$lock/start"
    printf 'Injected stale legacy identity (-27s): %s\n' "$(cat "$lock/start")"
  fi
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$fixture/bin/"
  fm_remote_job_ensure_worker "$fixture" "$fixture/account"
  new=$(cat "$lock/pid")
  ticks=$(cat "$lock/start")
  [ "$new" != "$old" ]
  ! kill -0 "$old" 2>/dev/null
  ! kill -0 -- "-$old_group" 2>/dev/null
  case "$ticks" in ''|*[!0-9]*) exit 1;; esac
  printf 'UPGRADE ready: pid=%s ticks=%s; old worker and supervisor group gone\n' "$new" "$ticks"
  for attempt in 1 2 3 4 5; do
    fm_remote_job_ensure_worker "$fixture" "$fixture/account"
    [ "$(cat "$lock/pid")" = "$new" ]
    printf 'Readiness call %s reused pid=%s repaired=%s\n' "$attempt" "$new" "$FM_REMOTE_JOB_REPAIRED"
  done
  fm_remote_job_stop_worker_tree "$new"
  printf 'Teardown: upgraded worker stopped\n'
done
export FM_REMOTE_JOB_STATE_ROOT="$LAB/guard-state"
fm_remote_job_prepare_state "$LAB/account"
lock=$(fm_remote_job_worker_lock_path)
mkdir -p "$lock"
sleep 120 &
unrelated=$!
printf '%s\n' "$unrelated" > "$lock/pid"
printf 'Mon Jan  1 00:00:00 2001\n' > "$lock/start"
fm_remote_job_process_command "$unrelated" > "$lock/command"
fm_remote_job_ensure_worker "$ROOT" "$LAB/account"
kill -0 "$unrelated"
new=$(cat "$lock/pid")
[ "$new" != "$unrelated" ]
printf 'SAFETY: unrelated pid=%s survived legacy lock recovery; ready worker=%s\n' "$unrelated" "$new"
# Exercise the real queue, lane, and claim identities using a tracked read-only command.
mkdir -p "$LAB/home/data"
printf 'identity live probe\n' > "$LAB/home/data/replies.log"
fm_remote_job_stage "$LAB/account" "$ROOT" "$LAB/home" fm-remote-delta-read.sh data/replies.log 0 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 1 < /dev/null
job=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$LAB/account" "$job"
printf 'QUEUE job=%s exit=%s stdout:\n' "$job" "$FM_REMOTE_JOB_EXIT"
cat "$FM_REMOTE_JOB_STATE/jobs/$job/stdout"
[ "$FM_REMOTE_JOB_EXIT" = 0 ]
fm_remote_job_reap "$LAB/account" "$job"
fm_remote_job_stop_worker_tree "$new"
kill "$unrelated"
wait "$unrelated" 2>/dev/null || true
printf 'Teardown: guard worker and unrelated process stopped\n'
