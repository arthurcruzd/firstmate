#!/bin/bash
# usage: snap.sh <lab> <code> <home> <id>
LAB=$1; CODE=$2; H=$3; ID=$4
echo "state files: $(ls -A "$H/state" | tr '\n' ' ')"
echo "data entries: $(ls -A "$H/data" | tr '\n' ' ')"
echo "config entries: $(ls -A "$H/config" | tr '\n' ' ')"
echo "pool entries (depth<=3): $(find "$LAB/pool" -mindepth 1 -maxdepth 3 | wc -l | tr -d ' ')"
echo "/tmp/fm-$ID dirs: $(ls -d /tmp/fm-"$ID" /tmp/fm-"$ID"+* 2>/dev/null | wc -l | tr -d ' ')"
echo "labproj git worktrees: $(git -C "$H/projects/labproj" worktree list | wc -l | tr -d ' ')"
node "$LAB/tools/t3probe.mjs" "$CODE" "$LAB/home/config/t3code-token" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("T3 projects=%d threads=%d" % (d["projectCount"], d["threadCount"]))'
