#!/usr/bin/env bash
# Live driver for remote-job process identity on this Linux host.
# Isolated fixtures only; never touches a default Herdr session or operator home.
set -u
umask 022
export LC_ALL=C

EV="/root/.no-mistakes/evidence/01M36SBMJKSME9J5T7VM2GGSM3"
ROOT="/root/.no-mistakes/worktrees/9ebe5b46efa6/01M36SBMJKSME9J5T7VM2GGSM3"
LIVE=$(mktemp -d /tmp/fm-remote-job-live.XXXXXX)
TRANSCRIPT="$EV/live-identity-transcript.log"
RESULTS="$EV/live-identity-results.txt"

exec > >(tee -a "$TRANSCRIPT") 2>&1

pass_count=0
fail_count=0
declare -a RESULTS_LINES=()

log() { printf '%s\n' "$*"; }
hr() { printf '\n===== %s =====\n' "$1"; }

record() {
  local status=$1 name=$2 detail=$3
  RESULTS_LINES+=("$status	$name	$detail")
  if [ "$status" = PASS ]; then
    pass_count=$((pass_count + 1))
    log "PASS: $name — $detail"
  else
    fail_count=$((fail_count + 1))
    log "FAIL: $name — $detail"
  fi
}

independent_starttime() {
  local pid=$1
  python3 - "$pid" <<'PY'
import sys
pid = sys.argv[1]
text = open(f"/proc/{pid}/stat").read()
rest = text[text.rfind(")") + 1:].split()
print(rest[19])
PY
}

count_workers() {
  local needle=$1
  pgrep -f "$needle" 2>/dev/null | wc -l | tr -d ' '
}

worker_ps() {
  local needle=$1
  ps -eo pid,lstart,command | grep -F "$needle" | grep -v grep || true
}

cleanup_live() {
  local child
  if [ -n "${LIVE:-}" ] && [ -d "$LIVE" ]; then
    pkill -TERM -f "$LIVE" 2>/dev/null || true
    sleep 0.3
    pkill -KILL -f "$LIVE" 2>/dev/null || true
  fi
  for child in $(jobs -pr 2>/dev/null); do
    kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  done
}
trap cleanup_live EXIT

mkdir -p "$LIVE"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

hr "host"
log "uname=$(uname -srm)"
log "live_root=$LIVE"
log "btime=$(awk '/btime/ {print $2}' /proc/stat)"
log "date=$(date)"

# ---------------------------------------------------------------------------
hr "S1 Linux start identity is /proc starttime ticks, not ps lstart"
sleep 60 &
s1_pid=$!
sleep 0.05
s1_ident=$(fm_remote_job_process_start "$s1_pid") || s1_ident="ERROR"
s1_ident2=$(fm_remote_job_process_start "$s1_pid") || s1_ident2="ERROR"
s1_proc=$(independent_starttime "$s1_pid") || s1_proc="ERROR"
s1_lstart=$(ps -p "$s1_pid" -o lstart= 2>/dev/null || true)
s1_comm=$(tr -d '\0' < "/proc/$s1_pid/comm")
log "pid=$s1_pid comm=$s1_comm"
log "identity1=$s1_ident"
log "identity2=$s1_ident2"
log "proc_field22=$s1_proc"
log "ps_lstart=$s1_lstart"
if [[ "$s1_ident" =~ ^[0-9]+$ ]] && [ "$s1_ident" = "$s1_proc" ] && [ "$s1_ident" = "$s1_ident2" ] && [ "$s1_ident" != "$s1_lstart" ] && [ -n "$s1_lstart" ]; then
  record PASS "linux-ticks-not-lstart" "pid $s1_pid identity=$s1_ident field22=$s1_proc lstart='$s1_lstart'"
else
  record FAIL "linux-ticks-not-lstart" "ident=$s1_ident ident2=$s1_ident2 field22=$s1_proc lstart='$s1_lstart'"
fi
kill "$s1_pid" 2>/dev/null || true
wait "$s1_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
hr "S2 owner match uses ticks; mismatched ticks and legacy lstart are rejected"
s2_home="$LIVE/s2-account"
s2_state="$LIVE/s2-state"
mkdir -p "$s2_home"
export FM_REMOTE_JOB_STATE_ROOT="$s2_state"
sleep 60 &
s2_pid=$!
sleep 0.05
s2_ticks=$(fm_remote_job_process_start "$s2_pid")
s2_cmd=$(fm_remote_job_process_command "$s2_pid")
s2_lstart=$(ps -p "$s2_pid" -o lstart=)
fm_remote_job_prepare_state "$s2_home"
s2_lock=$(fm_remote_job_worker_lock_path)
mkdir -p "$s2_lock"
printf '%s\n' "$s2_pid" > "$s2_lock/pid"
printf '%s\n' "$s2_ticks" > "$s2_lock/start"
printf '%s\n' "$s2_cmd" > "$s2_lock/command"
s2_match=0
fm_remote_job_lock_owner_matches_process "$s2_home" && s2_match=1
printf '%s\n' "$s2_lstart" > "$s2_lock/start"
s2_lstart_st=0
fm_remote_job_lock_owner_matches_process "$s2_home" || s2_lstart_st=$?
printf '%s\n' "$((s2_ticks + 1))" > "$s2_lock/start"
s2_tick_st=0
fm_remote_job_lock_owner_matches_process "$s2_home" || s2_tick_st=$?
log "ticks=$s2_ticks cmd=$s2_cmd lstart='$s2_lstart'"
log "match_ticks=$s2_match reject_lstart=$s2_lstart_st reject_wrong_tick=$s2_tick_st"
if [ "$s2_match" -eq 1 ] && [ "$s2_lstart_st" -eq 1 ] && [ "$s2_tick_st" -eq 1 ]; then
  record PASS "owner-match-ticks-reject-mismatch" "match=1 lstart_reject=$s2_lstart_st tick_reject=$s2_tick_st"
else
  record FAIL "owner-match-ticks-reject-mismatch" "match=$s2_match lstart_st=$s2_lstart_st tick_st=$s2_tick_st"
fi
kill "$s2_pid" 2>/dev/null || true
wait "$s2_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
hr "S3 live process with parentheses in comm still yields field-22 ticks"
s3_bin="$LIVE/sleep(x)y"
cp /bin/sleep "$s3_bin"
chmod +x "$s3_bin"
"$s3_bin" 60 &
s3_pid=$!
sleep 0.05
s3_ident=$(fm_remote_job_process_start "$s3_pid") || s3_ident="ERROR"
s3_proc=$(independent_starttime "$s3_pid") || s3_proc="ERROR"
s3_stat=$(cat "/proc/$s3_pid/stat")
s3_comm=$(tr -d '\0' < "/proc/$s3_pid/comm")
log "pid=$s3_pid comm='$s3_comm'"
log "stat=$s3_stat"
log "identity=$s3_ident field22=$s3_proc"
if [[ "$s3_comm" == *'('* ]] && [[ "$s3_ident" =~ ^[0-9]+$ ]] && [ "$s3_ident" = "$s3_proc" ]; then
  record PASS "paren-comm-ticks" "comm='$s3_comm' identity=$s3_ident"
else
  record FAIL "paren-comm-ticks" "comm='$s3_comm' ident=$s3_ident field22=$s3_proc"
fi
kill "$s3_pid" 2>/dev/null || true
wait "$s3_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
hr "S4 lstart fallback when /proc is unavailable"
sleep 60 &
s4_pid=$!
sleep 0.05
s4_home="$LIVE/s4-account"
s4_state="$LIVE/s4-state"
mkdir -p "$s4_home"
export FM_REMOTE_JOB_STATE_ROOT="$s4_state"
export FM_PROC_ROOT_OVERRIDE="$LIVE/no-proc"
s4_ident=$(fm_remote_job_process_start "$s4_pid") || s4_ident="ERROR"
s4_lstart=$(ps -p "$s4_pid" -o lstart=)
s4_cmd=$(fm_remote_job_process_command "$s4_pid")
fm_remote_job_prepare_state "$s4_home"
s4_lock=$(fm_remote_job_worker_lock_path)
mkdir -p "$s4_lock"
printf '%s\n' "$s4_pid" > "$s4_lock/pid"
printf '%s\n' "$s4_ident" > "$s4_lock/start"
printf '%s\n' "$s4_cmd" > "$s4_lock/command"
s4_match=0
fm_remote_job_lock_owner_matches_process "$s4_home" && s4_match=1
printf '%s\n' "Mon Jan  1 00:00:00 2001" > "$s4_lock/start"
s4_mis=0
fm_remote_job_lock_owner_matches_process "$s4_home" || s4_mis=$?
log "fallback_ident='$s4_ident'"
log "ps_lstart='$s4_lstart'"
log "match=$s4_match mismatch_status=$s4_mis"
unset FM_PROC_ROOT_OVERRIDE
if [ "$s4_ident" = "$s4_lstart" ] && [[ "$s4_ident" == *[!0-9]* ]] && [ "$s4_match" -eq 1 ] && [ "$s4_mis" -eq 1 ]; then
  record PASS "lstart-fallback-mismatch" "ident='$s4_ident' match=1 mismatch=1"
else
  record FAIL "lstart-fallback-mismatch" "ident='$s4_ident' lstart='$s4_lstart' match=$s4_match mis=$s4_mis"
fi
kill "$s4_pid" 2>/dev/null || true
wait "$s4_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
make_fixture() {
  local dest=$1
  mkdir -p "$dest/bin" "$dest/account"
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$dest/bin/"
  chmod 0755 "$dest/bin/fm-remote-job-lib.sh" "$dest/bin/fm-remote-job-worker.sh"
  printf 'fixture\n' > "$dest/AGENTS.md"
}

patch_legacy() {
  local dest=$1
  cat >> "$dest/bin/fm-remote-job-lib.sh" <<'LEGACY'
fm_remote_job_process_start() {
  local ps_bin
  if [ -x /bin/ps ]; then ps_bin=/bin/ps; else ps_bin=/usr/bin/ps; fi
  "$ps_bin" -p "$1" -o lstart=
}
LEGACY
}

# ---------------------------------------------------------------------------
hr "S5 live Linux worker records tick identity; repeated ensure does not pile up"
s5="$LIVE/s5-checkout"
make_fixture "$s5"
export FM_REMOTE_JOB_STATE_ROOT="$s5/state"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
unset FM_PROC_ROOT_OVERRIDE
if fm_remote_job_ensure_worker "$s5" "$s5/account"; then
  s5_lock=$(fm_remote_job_worker_lock_path)
  s5_pid=$(cat "$s5_lock/pid")
  s5_start=$(cat "$s5_lock/start")
  s5_cmd=$(cat "$s5_lock/command")
  s5_count1=$(count_workers "$s5/bin/fm-remote-job-worker.sh")
  log "first pid=$s5_pid start=$s5_start cmd=$s5_cmd count=$s5_count1"
  log "ps:"; worker_ps "$s5/bin/fm-remote-job-worker.sh"
  s5_ok=1
  s5_i=0
  while [ "$s5_i" -lt 5 ]; do
    s5_i=$((s5_i + 1))
    if ! fm_remote_job_ensure_worker "$s5" "$s5/account"; then
      s5_ok=0
      log "ensure #$s5_i failed: ${FM_REMOTE_JOB_ERROR:-unknown}"
      break
    fi
    s5_pid_now=$(cat "$s5_lock/pid")
    s5_count_now=$(count_workers "$s5/bin/fm-remote-job-worker.sh")
    log "ensure #$s5_i pid=$s5_pid_now count=$s5_count_now repaired=${FM_REMOTE_JOB_REPAIRED:-}"
    if [ "$s5_pid_now" != "$s5_pid" ] || [ "$s5_count_now" != "$s5_count1" ]; then
      s5_ok=0
      log "pile-up or replacement on ensure #$s5_i"
      break
    fi
  done
  s5_count_final=$(count_workers "$s5/bin/fm-remote-job-worker.sh")
  if [ "$s5_ok" -eq 1 ] && [[ "$s5_start" =~ ^[0-9]+$ ]] && [ "$s5_count1" = 2 ] && [ "$s5_count_final" = 2 ]; then
    record PASS "repeated-ensure-no-pileup" "pid=$s5_pid start=$s5_start workers=$s5_count_final"
  else
    record FAIL "repeated-ensure-no-pileup" "ok=$s5_ok pid=$s5_pid start=$s5_start count1=$s5_count1 countf=$s5_count_final err=${FM_REMOTE_JOB_ERROR:-}"
  fi
  cp -a "$s5_lock/pid" "$EV/s5-lock.pid" 2>/dev/null || true
  cp -a "$s5_lock/start" "$EV/s5-lock.start" 2>/dev/null || true
  cp -a "$s5_lock/command" "$EV/s5-lock.command" 2>/dev/null || true
else
  record FAIL "repeated-ensure-no-pileup" "ensure failed: ${FM_REMOTE_JOB_ERROR:-unknown}"
fi
pkill -TERM -f "$s5/bin/fm-remote-job-worker.sh" 2>/dev/null || true
sleep 0.4
pkill -KILL -f "$s5/bin/fm-remote-job-worker.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
hr "S6 Linux upgrade handoff of a live legacy-lstart worker, including 27s drift"
s6="$LIVE/s6-checkout"
make_fixture "$s6"
patch_legacy "$s6"
export FM_REMOTE_JOB_STATE_ROOT="$s6/state"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
if fm_remote_job_ensure_worker "$s6" "$s6/account"; then
  s6_lock=$(fm_remote_job_worker_lock_path)
  s6_old=$(cat "$s6_lock/pid")
  s6_start=$(cat "$s6_lock/start")
  s6_cmd=$(cat "$s6_lock/command")
  s6_count_old=$(count_workers "$s6/bin/fm-remote-job-worker.sh")
  log "legacy pid=$s6_old start='$s6_start' cmd='$s6_cmd' count=$s6_count_old"
  log "legacy ps:"; worker_ps "$s6/bin/fm-remote-job-worker.sh"
  printf '%s\n' "$s6_start" > "$EV/s6-legacy.start"
  printf '%s\n' "$s6_old" > "$EV/s6-legacy.pid"
  printf '%s\n' "$s6_cmd" > "$EV/s6-legacy.command"
  if [[ "$s6_start" == *[!0-9]* ]]; then
    cp "$ROOT/bin/fm-remote-job-lib.sh" "$s6/bin/fm-remote-job-lib.sh"
    s6_drifted=$(date -d "$s6_start 27 seconds ago" '+%a %b %e %T %Y') || s6_drifted=""
    log "drifted_start='$s6_drifted'"
    printf '%s\n' "$s6_drifted" > "$s6_lock/start"
    printf '%s\n' "$s6_drifted" > "$EV/s6-drifted.start"
    if fm_remote_job_ensure_worker "$s6" "$s6/account"; then
      s6_new=$(cat "$s6_lock/pid")
      s6_newstart=$(cat "$s6_lock/start")
      s6_newcmd=$(cat "$s6_lock/command")
      s6_old_alive=0
      kill -0 "$s6_old" 2>/dev/null && s6_old_alive=1
      s6_count_new=$(count_workers "$s6/bin/fm-remote-job-worker.sh")
      log "replacement pid=$s6_new start=$s6_newstart cmd='$s6_newcmd' old_alive=$s6_old_alive count=$s6_count_new"
      log "replacement ps:"; worker_ps "$s6/bin/fm-remote-job-worker.sh"
      printf '%s\n' "$s6_new" > "$EV/s6-new.pid"
      printf '%s\n' "$s6_newstart" > "$EV/s6-new.start"
      printf '%s\n' "$s6_newcmd" > "$EV/s6-new.command"
      s6_repeat_ok=1
      s6_i=0
      while [ "$s6_i" -lt 3 ]; do
        s6_i=$((s6_i + 1))
        if ! fm_remote_job_ensure_worker "$s6" "$s6/account"; then
          s6_repeat_ok=0
          log "post-upgrade ensure #$s6_i failed: ${FM_REMOTE_JOB_ERROR:-}"
          break
        fi
        s6_now=$(cat "$s6_lock/pid")
        s6_cnow=$(count_workers "$s6/bin/fm-remote-job-worker.sh")
        log "post-upgrade ensure #$s6_i pid=$s6_now count=$s6_cnow"
        if [ "$s6_now" != "$s6_new" ] || [ "$s6_cnow" != "$s6_count_new" ]; then
          s6_repeat_ok=0
          break
        fi
      done
      if [ "$s6_new" != "$s6_old" ] && [ "$s6_old_alive" -eq 0 ] && [[ "$s6_newstart" =~ ^[0-9]+$ ]] && [ "$s6_count_new" = 2 ] && [ "$s6_repeat_ok" -eq 1 ]; then
        record PASS "legacy-upgrade-with-drift" "old=$s6_old new=$s6_new ticks=$s6_newstart workers=$s6_count_new"
      else
        record FAIL "legacy-upgrade-with-drift" "old=$s6_old new=$s6_new alive=$s6_old_alive start=$s6_newstart count=$s6_count_new repeat=$s6_repeat_ok"
      fi
    else
      record FAIL "legacy-upgrade-with-drift" "upgraded ensure failed: ${FM_REMOTE_JOB_ERROR:-unknown}"
    fi
  else
    record FAIL "legacy-upgrade-with-drift" "fixture did not record lstart ('$s6_start')"
  fi
else
  record FAIL "legacy-upgrade-with-drift" "legacy ensure failed: ${FM_REMOTE_JOB_ERROR:-unknown}"
fi
pkill -TERM -f "$s6/bin/fm-remote-job-worker.sh" 2>/dev/null || true
sleep 0.4
pkill -KILL -f "$s6/bin/fm-remote-job-worker.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
hr "S7 adversarial: unrelated live pid with legacy lstart is not stopped"
s7="$LIVE/s7-checkout"
make_fixture "$s7"
export FM_REMOTE_JOB_STATE_ROOT="$s7/state"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
sleep 60 &
s7_sleep=$!
sleep 0.05
s7_lstart=$(ps -p "$s7_sleep" -o lstart=)
s7_cmd=$(fm_remote_job_process_command "$s7_sleep")
fm_remote_job_prepare_state "$s7/account"
s7_lock=$(fm_remote_job_worker_lock_path)
mkdir -p "$s7_lock"
printf '%s\n' "$s7_sleep" > "$s7_lock/pid"
printf '%s\n' "$s7_lstart" > "$s7_lock/start"
printf '%s\n' "$s7_cmd" > "$s7_lock/command"
touch -d '90 seconds ago' "$s7_lock"
log "planted unrelated pid=$s7_sleep start='$s7_lstart' cmd='$s7_cmd'"
if fm_remote_job_ensure_worker "$s7" "$s7/account"; then
  s7_alive=0
  kill -0 "$s7_sleep" 2>/dev/null && s7_alive=1
  s7_new=$(cat "$s7_lock/pid")
  s7_newstart=$(cat "$s7_lock/start")
  s7_count=$(count_workers "$s7/bin/fm-remote-job-worker.sh")
  log "sleep_alive=$s7_alive new_pid=$s7_new new_start=$s7_newstart workers=$s7_count"
  worker_ps "$s7/bin/fm-remote-job-worker.sh"
  if [ "$s7_alive" -eq 1 ] && [ "$s7_new" != "$s7_sleep" ] && [[ "$s7_newstart" =~ ^[0-9]+$ ]]; then
    record PASS "unrelated-legacy-pid-not-killed" "sleep=$s7_sleep survived; worker=$s7_new"
  else
    record FAIL "unrelated-legacy-pid-not-killed" "alive=$s7_alive sleep=$s7_sleep new=$s7_new start=$s7_newstart"
  fi
else
  s7_alive=0
  kill -0 "$s7_sleep" 2>/dev/null && s7_alive=1
  if [ "$s7_alive" -eq 1 ]; then
    record PASS "unrelated-legacy-pid-not-killed" "ensure failed but sleep $s7_sleep survived: ${FM_REMOTE_JOB_ERROR:-}"
  else
    record FAIL "unrelated-legacy-pid-not-killed" "sleep was killed; ensure failed: ${FM_REMOTE_JOB_ERROR:-}"
  fi
fi
kill "$s7_sleep" 2>/dev/null || true
wait "$s7_sleep" 2>/dev/null || true
pkill -TERM -f "$s7/bin/fm-remote-job-worker.sh" 2>/dev/null || true
sleep 0.3
pkill -KILL -f "$s7/bin/fm-remote-job-worker.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
hr "summary"
{
  printf 'pass=%s fail=%s\n' "$pass_count" "$fail_count"
  printf '%s\n' "${RESULTS_LINES[@]}"
} | tee "$RESULTS"

cleanup_live
trap - EXIT
# Extra sweep in case jobs remain
pkill -KILL -f "$LIVE" 2>/dev/null || true
rm -rf "$LIVE" 2>/dev/null || true

if [ "$fail_count" -eq 0 ]; then
  exit 0
fi
exit 1
