#!/bin/bash
# Live away-mode digest freeze/restamp against the lab T3 through the lossy proxy.
# usage: away-next-since.sh <worktree> <lab> <supervisor-thread>
W=$1; LAB=$2; SUP=$3
export FM_HOME=$LAB/away FM_WEDGE_ALARM_CHANNEL=off
. "$W/bin/fm-backend.sh"; fm_backend_source t3code || exit 1
. "$W/bin/fm-supervise-daemon.sh"
FM_SUPERVISOR_TARGET=$SUP FM_SUPERVISOR_BACKEND=t3code FM_DAEMON_PRIMARY_HARNESS=claude
S=$FM_HOME/state
buf=$S/.subsuper-escalations
sup_state() { node "$W/bin/fm-t3-mcp.mjs" state --thread "$SUP" 2>/dev/null; }
wait_idle() {
  local i
  for i in $(seq 1 90); do
    sup_state | grep -q '"activeRunId":null' && return 0
    sleep 2
  done
  return 1
}
files() { ls -a "$S" | grep '^\.subsuper-escalations' | tr '\n' ' '; }

printf 'drop\n' > "$LAB/proxy/plan"
afk_enter "$S"
echo "t0=$(_now) afk_enter"
escalate_add "$S" "lab event-one: crew lab7 blocked, waiting on a captain answer"
escalate_flush "$S"; echo "flush1 rc=$? verdict=${INJECT_LAST_VERDICT:-} failure=${INJECT_LAST_FAILURE:-}"
echo "after flush1: $(files)"
echo "frozen header: $(head -n 2 "$buf.frozen" 2>/dev/null | tr '\n' ' ')"
echo "since=$(cat "$buf.since" 2>/dev/null)"
sleep 20
t2=$(_now)
escalate_add "$S" "lab event-two: crew lab8 blocked, waiting on a captain answer"
echo "t2=$t2 event-two added; .next-since=$(cat "$buf.next-since" 2>/dev/null || echo MISSING)"
sleep 20
escalate_add "$S" "lab event-three: crew lab9 blocked, waiting on a captain answer"
echo "t3=$(_now) event-three added; .next-since=$(cat "$buf.next-since" 2>/dev/null || echo MISSING) (unchanged by a later add)"
echo "supervisor before retry: $(sup_state)"
wait_idle && echo "supervisor idle (the committed-but-unconfirmed event-one digest ran its turn)" || echo "supervisor still busy"
# The frozen retry passes; the next generation's own send is dropped too, so
# the since-stamp it carries is visible in its own frozen header.
printf 'pass\ndrop\n' > "$LAB/proxy/plan"
t4=$(_now)
escalate_flush "$S"; echo "flush2 at t4=$t4 rc=$? verdict=${INJECT_LAST_VERDICT:-} failure=${INJECT_LAST_FAILURE:-}"
echo "after flush2: $(files)"
echo "buffer now: $(tr '\n' '|' < "$buf")"
echo "since=$(cat "$buf.since" 2>/dev/null || echo none)"
echo "frozen header: $(head -n 2 "$buf.frozen" 2>/dev/null | tr '\n' ' ')"
echo "oldest-line age at t4: $(( t4 - $(cat "$buf.since" 2>/dev/null || echo "$t4") ))s  (t4 - t2 = $(( t4 - t2 ))s; t4 - t0 >= $(( t4 - t2 + 20 ))s)"
wait_idle && echo "supervisor idle again"
printf '' > "$LAB/proxy/plan"
escalate_flush "$S"; echo "flush3 rc=$? verdict=${INJECT_LAST_VERDICT:-}"
echo "after flush3: $(files)"
echo "buffer bytes: $(wc -c < "$buf" | tr -d ' ')"
