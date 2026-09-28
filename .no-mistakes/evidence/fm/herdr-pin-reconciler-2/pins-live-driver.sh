#!/usr/bin/env bash
# Live driver: runs from the gate worktree against a disposable lab home; this
# host has no tmux and no Herdr pane around this process, so firstmate is not on Herdr.
set -u
cd "$WT"
OBS="$FM_HOME/obs"; mkdir -p "$OBS"
REAL_HERDR=$(command -v herdr)
# Pass-through observer: records any herdr invocation, then runs the real herdr.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$FM_HOME/herdr-calls.log" "$REAL_HERDR" > "$OBS/herdr"
chmod +x "$OBS/herdr"
export PATH="$OBS:$PATH"
: > "$FM_HOME/herdr-calls.log"
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
calls() { printf '>> herdr invocations so far: %s\n' "$(wc -l < "$FM_HOME/herdr-calls.log" | tr -d ' ')"; }
tick() { bash -c '. bin/fm-secondmate-liveness-lib.sh; STATE=$FM_HOME/state CONFIG=$FM_HOME/config fm_secondmate_liveness_pins "$1"' _ "$1"; }

echo "supervisor pane: TMUX_PANE=${TMUX_PANE:-unset} HERDR_ENV=${HERDR_ENV:-unset}  FM_HOME=$FM_HOME"
echo; echo "===== A. pins OFF: no config/pinned-agents ====="
run bin/fm-herdr-pins.sh sync
run bin/fm-herdr-pins.sh clear legal-clerk
run tick poll
run ls -A "$FM_HOME/state"
calls

echo; echo "===== B. pins ON (captain's labels), firstmate + a local mate on tmux ====="
cat > "$FM_HOME/config/pinned-agents" <<'EOF'
# <rank> <id> <host> <label>
1 self        VPS Firstmate
2 legal-clerk Mac Legal Clerk
3 machinist   Mac Machinist
5 pbi         WSL Power BI
EOF
printf 'window=firstmate:fm-machinist\nendpoint_task_id=machinist\nworktree=%s/homes/machinist\nproject=%s/homes/machinist\nharness=claude\nkind=secondmate\nmode=secondmate\nhome=%s/homes/machinist\n' "$FM_HOME" "$FM_HOME" "$FM_HOME" > "$FM_HOME/state/machinist.meta"
run cat "$FM_HOME/config/pinned-agents"
run bin/fm-herdr-pins.sh sync
run bin/fm-herdr-pins.sh sync machinist
run env FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=firstmate:0.0 bin/fm-herdr-pins.sh sync self
run bin/fm-herdr-pins.sh clear machinist
run bin/fm-herdr-pins.sh clear not-pinned
calls

echo; echo "===== C. session-start network stage with pins ON (tmux) ====="
printf '\n$ FM_BOOTSTRAP_NETWORK=only FM_TIMING_LOG=... bin/fm-bootstrap.sh\n'
FM_BOOTSTRAP_NETWORK=only FM_TIMING_LOG="$FM_HOME/timing.log" bin/fm-bootstrap.sh > "$FM_HOME/bootstrap.out" 2>&1
printf '[exit %s]\n' "$?"
sed 's/^/  | /' "$FM_HOME/bootstrap.out" | tail -15
printf '\n$ grep phase timing.log (phase, name, ms)\n'
awk -F'\t' '$0 ~ /phase/ {print "  " $0}' "$FM_HOME/timing.log" | cut -c1-120
calls

echo; echo "===== D. watcher liveness tick cadence (FM_HERDR_PINS_SECS default 300) ====="
rm -f "$FM_HOME/state/.herdr-pins-tick"
run tick poll; M1=$(cat "$FM_HOME/state/.herdr-pins-tick"); echo "marker after 1st poll: $M1"
sleep 2
run tick poll; M2=$(cat "$FM_HOME/state/.herdr-pins-tick"); echo "marker after 2nd poll (inside cadence): $M2  -> $([ "$M1" = "$M2" ] && echo unchanged, no re-assert || echo CHANGED)"
export FM_HERDR_PINS_SECS=1
run tick poll; M3=$(cat "$FM_HOME/state/.herdr-pins-tick"); echo "marker with FM_HERDR_PINS_SECS=1 after 2s: $M3 -> $([ "$M3" -gt "$M1" ] && echo re-asserted || echo NOT re-asserted)"
unset FM_HERDR_PINS_SECS
mv "$FM_HOME/config/pinned-agents" "$FM_HOME/config/pinned-agents.off"; rm -f "$FM_HOME/state/.herdr-pins-tick"
run tick poll; echo "marker with pins off: $([ -e "$FM_HOME/state/.herdr-pins-tick" ] && echo PRESENT || echo absent)"
mv "$FM_HOME/config/pinned-agents.off" "$FM_HOME/config/pinned-agents"
calls

echo; echo "===== E. adversarial input never reaches Herdr ====="
cat > "$FM_HOME/config/pinned-agents" <<'EOF'
1 self VPS Firstmate
0 zero Mac Zero rank
100 big Mac Rank too big
2 bad/id Mac Bad id
3 legal2 bad^host Bad host
4 legal Mac
6 legal - Legal Clerk
7 dup Mac First
8 dup Mac Second
EOF
run bin/fm-herdr-pins.sh sync
run bin/fm-herdr-pins.sh tag fm-lab-x w1:p1 3 Mac Label
run bin/fm-herdr-pins.sh tag fm-lab-x w1:p1 03 'bad host' Label
run bin/fm-herdr-pins.sh tag fm-lab-x w1:p1 03 Mac "$(printf 'evil\033[2Jlabel')"
run bin/fm-herdr-pins.sh view ../evil
run bin/fm-herdr-pins.sh untag 'a;b' w1:p1
run bin/backends/herdr-agent-view.py relative.sock
run bin/backends/herdr-agent-view.py /nonexistent/socket clear
run bin/backends/herdr-agent-view.py /nonexistent/socket
calls
echo; echo "DRIVER DONE"
