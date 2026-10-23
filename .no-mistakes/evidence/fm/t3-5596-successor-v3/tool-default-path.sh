#!/bin/bash
# usage: default-path.sh <code-root> <lab-home> <lab>
CODE=$1; H=$2; LAB=$3
cd "$CODE" || exit 1
for id in d1 d2; do
  FM_HOME=$H bin/fm-brief.sh $id labproj --scout >/dev/null 2>&1
  python3 - "$H/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("{TASK}","Find out what the first line of the labproj README says.",1)
s=s.replace("{FIRSTMATE_SPEC}","Run `head -n 1 README.md` and report it.",1)
open(p,"w").write(s)
PY
done
printf 'approve-for-me\n' > "$H/config/codex-approval-mode"
echo "config: $(ls -A "$H/config" | tr '\n' ' ') (no config/backend; codex-approval-mode=approve-for-me; a valid t3code-token credential is present but must not select T3)"
echo "== A. codex scout spawn"
rc=0; out=$(CODEX_HOME=$LAB/codex-cfg CLAUDE_CONFIG_DIR=$LAB/claude-trust TREEHOUSE_ROOT=$LAB/pool-default FM_HOME=$H bin/fm-spawn.sh d1 "$H/projects/labproj" --scout --harness codex --model gpt-6-luna --effort low 2>&1) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -v 'treehouse is available\|treehouse update'
echo "state files for d1: $(ls -A "$H/state" | grep -c '^d1\.')"
echo "== B. claude scout spawn"
rc=0; out=$(CLAUDE_CONFIG_DIR=$LAB/claude-trust TREEHOUSE_ROOT=$LAB/pool-default FM_HOME=$H bin/fm-spawn.sh d2 "$H/projects/labproj" --scout --harness claude --model claude-haiku-5-5 --effort low 2>&1) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -v 'treehouse is available\|treehouse update'
echo "state files for d2: $(ls -A "$H/state" | grep -c '^d2\.')"
rm -f "$H/config/codex-approval-mode"
echo "== C. managed approval failover on a recorded local tmux Claude task (hand-written record: harness=claude approval_mode=bypass, no backend line)"
printf 'window=fm-f1\nendpoint_task_id=f1\nharness=claude\napproval_mode=bypass\nkind=scout\n' > "$H/state/f1.meta"
rc=0; out=$(FM_HOME=$H bin/fm-approval-failover.sh apply f1 2>&1) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "config/claude-permission-mode=$(cat "$H/config/claude-permission-mode" 2>/dev/null || echo ABSENT)"
rm -f "$H/config/claude-permission-mode" "$H/state/f1.meta"
echo "== D. same with a Codex record"
printf 'window=fm-f2\nendpoint_task_id=f2\nharness=codex\napproval_mode=bypass\nkind=scout\n' > "$H/state/f2.meta"
rc=0; out=$(FM_HOME=$H bin/fm-approval-failover.sh apply f2 2>&1) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "config/codex-approval-mode=$(cat "$H/config/codex-approval-mode" 2>/dev/null || echo ABSENT)"
rm -f "$H/config/codex-approval-mode" "$H/state/f2.meta"
