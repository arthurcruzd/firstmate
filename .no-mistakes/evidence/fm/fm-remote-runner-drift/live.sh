#!/bin/bash
set -eu
umask 022
ROOT=$PWD
LAB="$ROOT/.test-remote-identity/live"
mkdir -p "$LAB/root/bin" "$LAB/account" "$LAB/home/state"
cp AGENTS.md "$LAB/root/AGENTS.md"
cp bin/fm-remote-job-worker.sh bin/fm-remote-delta-read.sh "$LAB/root/bin/"
git show e0d95ac770dee9dde8a59330656357ab2e5fd74e:bin/fm-remote-job-lib.sh > "$LAB/root/bin/fm-remote-job-lib.sh"
git -C "$LAB/root" init -q
git -C "$LAB/root" add bin
export FM_REMOTE_JOB_STATE_ROOT="$LAB/state"
unset FM_PROC_ROOT_OVERRIDE FM_ROOT_OVERRIDE FM_REMOTE_JOB_PLATFORM_OVERRIDE
. "$LAB/root/bin/fm-remote-job-lib.sh"
cleanup() {
  for p in $(jobs -pr); do kill -TERM -- "-$p" 2>/dev/null || true; done
  wait || true
}
trap cleanup EXIT
fm_remote_job_ensure_worker "$LAB/root" "$LAB/account"
lock=$(fm_remote_job_worker_lock_path)
old=$(cat "$lock/pid")
printf 'Baseline worker pid=%s identity=%s\n' "$old" "$(cat "$lock/start")"
# Persisted legacy identity simulates the stale timestamp left by btime drift.
printf 'Mon Jan  1 00:00:00 2001\n' > "$lock/start"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$LAB/root/bin/"
. "$LAB/root/bin/fm-remote-job-lib.sh"
fm_remote_job_ensure_worker "$LAB/root" "$LAB/account"
new=$(cat "$lock/pid")
[ "$new" != "$old" ]
! kill -0 "$old" 2>/dev/null
printf 'Upgraded worker pid=%s identity=%s; legacy pid stopped\n' "$new" "$(cat "$lock/start")"
for i in 1 2 3 4 5; do
  fm_remote_job_ensure_worker "$LAB/root" "$LAB/account"
  [ "$(cat "$lock/pid")" = "$new" ]
  printf 'readiness call %s: ready, same pid=%s\n' "$i" "$new"
done
printf 'identity-upgrade-job-ok\n' > "$LAB/home/state/reply.log"
sha=$(printf '' | sha256sum | cut -d ' ' -f1)
fm_remote_job_stage "$LAB/account" "$LAB/root" "$LAB/home" fm-remote-delta-read.sh state/reply.log 0 "$sha" 0 < /dev/null
id=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$LAB/account" "$id"
printf 'job=%s exit=%s stdout:\n' "$id" "$FM_REMOTE_JOB_EXIT"
cat "$FM_REMOTE_JOB_STDOUT"
cat "$FM_REMOTE_JOB_STDERR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ]
fm_remote_job_reap "$LAB/account" "$id"
fm_remote_job_stop_worker_tree "$new"
printf 'Worker stopped after completed queue job\n'
