#!/usr/bin/env bash
set -u
ROOT=/root/.no-mistakes/worktrees/9ebe5b46efa6/01M3TP63J6SZDBPM3VWF3GWCJR

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }

# 1) Normal path: BASHPID set, command runs
rc=0
out=$(. "$ROOT/bin/fm-timeout-lib.sh"; fm_exec_timed 5 1 bash -c 'echo ran-normal') || rc=$?
echo "normal: rc=$rc out=[$out]"
[ "$rc" -eq 0 ] && [ "$out" = ran-normal ] || fail "normal path rc=$rc out=$out"
ok "fm_exec_timed runs when BASHPID is set"

# 2) BASHPID unset under set -u (the macOS Bash 3.2 failure mode)
rc=0
out=$(unset BASHPID; . "$ROOT/bin/fm-timeout-lib.sh"; fm_exec_timed 5 1 bash -c 'echo ran-unset') || rc=$?
echo "unset: rc=$rc out=[$out]"
[ "$rc" -eq 0 ] && [ "$out" = ran-unset ] || fail "unset BASHPID path rc=$rc out=$out"
ok "fm_exec_timed runs under set -u when BASHPID is unset"

# 3) Pre-fix reproduction: old library dies on unbound BASHPID
rc=0
err=$(bash -c 'set -u; unset BASHPID; . /tmp/fm-timeout-lib-old.sh; fm_exec_timed 5 1 bash -c "echo should-not-run"' 2>&1) || rc=$?
echo "old-lib: rc=$rc err=[$err]"
[ "$rc" -ne 0 ] || fail "old library unexpectedly succeeded without BASHPID"
case "$err" in
  *unbound*) ok "pre-fix fm_exec_timed dies with unbound BASHPID under set -u" ;;
  *) fail "expected unbound variable from old library, got rc=$rc err=$err" ;;
esac

# 3b) Bare expansion still fails (the exact set -u case)
rc=0
err=$(bash -c 'set -u; unset BASHPID; echo "old=[$BASHPID]"' 2>&1) || rc=$?
echo "old-expansion: rc=$rc err=[$err]"
case "$err" in
  *unbound*) ok "pre-fix bare BASHPID fails unbound under set -u" ;;
  *) fail "expected unbound variable from bare BASHPID, got: $err" ;;
esac

# 4) Fallback PID equals real BASHPID in a fresh shell (isolated so we can unset)
pair=$(bash -c '
  set -u
  real=$BASHPID
  dollar=$$
  unset BASHPID
  fallback=${BASHPID:-$(exec sh -c "printf \"%s\\n\" \"\$PPID\"")}
  printf "%s %s %s" "$real" "$fallback" "$dollar"
')
echo "main_pair real fallback dollar= $pair"
set -- $pair
real=$1 fallback=$2 dollar=$3
[ "$real" = "$fallback" ] || fail "fallback PID $fallback != BASHPID $real"
[ "$fallback" = "$dollar" ] || fail "in main shell fallback $fallback != \$\$ $dollar"
ok "sh PPID fallback matches BASHPID in this shell"

# 5) In a subshell, fallback matches that subshell's BASHPID and not parent $$
pair=$(bash -c '
  set -u
  parent=$$
  (
    real=$BASHPID
    unset BASHPID
    fallback=${BASHPID:-$(exec sh -c "printf \"%s\\n\" \"\$PPID\"")}
    printf "%s %s %s %s" "$real" "$fallback" "$parent" "$$"
  )
')
echo "sub_pair real fallback parent dollar= $pair"
set -- $pair
real=$1 fallback=$2 parent=$3 dollar=$4
[ "$real" = "$fallback" ] || fail "subshell fallback $fallback != subshell BASHPID $real"
[ "$fallback" != "$parent" ] || fail "subshell fallback should differ from parent \$\$ ($parent)"
[ "$dollar" = "$parent" ] || fail "subshell \$\$ should still be parent pid"
ok "subshell fallback matches subshell BASHPID and differs from parent \$\$"

# 6) Status/output still pass through without BASHPID
rc=0
out=$(unset BASHPID; . "$ROOT/bin/fm-timeout-lib.sh"; fm_exec_timed 5 1 bash -c 'echo to-out; echo to-err >&2; exit 7' 2>&1) || rc=$?
echo "passthrough: rc=$rc out=[$out]"
[ "$rc" -eq 7 ] || fail "status not passed through rc=$rc"
case "$out" in
  *to-out*) ;;
  *) fail "stdout lost: $out" ;;
esac
case "$out" in
  *to-err*) ;;
  *) fail "stderr lost: $out" ;;
esac
ok "status and output pass through when BASHPID is unset"

# 7) Adversarial: empty BASHPID (not just unset) under set -u
rc=0
out=$(BASHPID=; . "$ROOT/bin/fm-timeout-lib.sh"; fm_exec_timed 5 1 bash -c 'echo ran-empty') || rc=$?
echo "empty: rc=$rc out=[$out]"
[ "$rc" -eq 0 ] && [ "$out" = ran-empty ] || fail "empty BASHPID path rc=$rc out=$out"
ok "fm_exec_timed runs when BASHPID is empty"

# 8) Command actually gets a bound (times out) with BASHPID unset
rc=0
started=$SECONDS
out=$(unset BASHPID; . "$ROOT/bin/fm-timeout-lib.sh"; fm_exec_timed 1 1 bash -c 'sleep 30; echo too-late') || rc=$?
elapsed=$((SECONDS - started))
echo "timeout: rc=$rc elapsed=${elapsed}s out=[$out]"
[ "$rc" -eq 124 ] || fail "bound did not report 124 with BASHPID unset (rc=$rc)"
[ "$elapsed" -ge 1 ] || fail "bound fired too early (${elapsed}s)"
[ "$elapsed" -lt 10 ] || fail "bound took too long (${elapsed}s)"
ok "fm_exec_timed still enforces the bound when BASHPID is unset"

# 9) Named owner that is already gone ends the command with BASHPID unset
gone=999999
if kill -0 "$gone" 2>/dev/null; then
  echo "NOTE: pid $gone is live; skipping gone-owner check"
else
  rc=0
  started=$SECONDS
  out=$(unset BASHPID; . "$ROOT/bin/fm-timeout-lib.sh"; FM_EXEC_TIMED_OWNER_PID=$gone fm_exec_timed 60 1 bash -c 'echo started; sleep 30') || rc=$?
  elapsed=$((SECONDS - started))
  echo "gone-owner: rc=$rc elapsed=${elapsed}s out=[$out]"
  [ "$elapsed" -lt 15 ] || fail "gone owner did not end the command (elapsed=${elapsed}s)"
  ok "named gone owner ends the command when BASHPID is unset"
fi

echo ALL_LIVE_CHECKS_DONE
