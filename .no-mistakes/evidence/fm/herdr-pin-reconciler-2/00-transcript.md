# Herdr pin validation transcript (isolated Herdr root, lab session fm-lab-pins-97740-22828, marked lab FM_HOME)

Real host Herdr sessions before (tripwire):
[{"name":"default","default":true,"running":false,"socket_path":"/Users/disco/.config/herdr/herdr.sock"},{"name":"fm-remote","default":false,"running":true,"socket_path":"/Users/disco/.config/herdr/sessions/fm-remote/herdr.sock"}]

## off-sync  (exit 0)
```
```

## off-clear  (exit 0)
```
```

## sync1  (exit 0)
```
pinned self fm-lab-pins-97740-22828:w1:p1
pinned legal-clerk fm-lab-pins-97740-22828:w1:p2
pinned machinist fm-lab-pins-97740-22828:w1:p3
pinned pbi fm-lab-pins-97740-22828:w1:p4
```

## sync2  (exit 0)
```
pinned self fm-lab-pins-97740-22828:w1:p1
pinned legal-clerk fm-lab-pins-97740-22828:w1:p2
pinned machinist fm-lab-pins-97740-22828:w1:p3
pinned pbi fm-lab-pins-97740-22828:w1:p4
```

## boot  (exit 0)
```
NEEDS_GH_AUTH
SECONDMATE_LIVENESS: secondmate legal-clerk: respawn failed after confirmed agent absence on existing endpoint: fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fmhp-home.KMLW
SECONDMATE_LIVENESS: secondmate machinist: respawn failed after confirmed agent absence on existing endpoint: fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fmhp-home.KMLW
SECONDMATE_LIVENESS: secondmate pbi: respawn failed after confirmed agent absence on existing endpoint: fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fmhp-home.KMLW
SECONDMATE_SYNC: secondmate legal-clerk: skipped: primary default-branch commit cannot be resolved
SECONDMATE_SYNC: secondmate machinist: skipped: primary default-branch commit cannot be resolved
SECONDMATE_SYNC: secondmate pbi: skipped: primary default-branch commit cannot be resolved
```

## sync-id  (exit 0)
```
pinned legal-clerk fm-lab-pins-97740-22828:w1:p6
```

## ta  (exit 0)
```
mode=poll rc=0 marker=1790561341
```

## tb  (exit 0)
```
mode=poll rc=0 marker=1790561341
```

## tc  (exit 0)
```
mode=full rc=0 marker=1790561341
```

## td  (exit 0)
```
mode=poll rc=0 marker=1790561349
```

## clr0  (exit 0)
```
```

## clr1  (exit 0)
```
cleared machinist
```

## s3  (exit 0)
```
pinned self fm-lab-pins-97740-22828:w1:p1
pinned legal-clerk fm-lab-pins-97740-22828:w1:p6
skipped machinist: no endpoint record
pinned pbi fm-lab-pins-97740-22828:w1:p8
```

## bad  (exit 0)
```
pinned-agents line 4: expected <rank 1-99> <self|secondmate-id> <host> <label>
pinned-agents line 5: expected <rank 1-99> <self|secondmate-id> <host> <label>
pinned-agents line 6: expected <rank 1-99> <self|secondmate-id> <host> <label>
pinned-agents line 7: expected <rank 1-99> <self|secondmate-id> <host> <label>
pinned-agents line 8: missing host or label; expected <rank> <id> <host> <label>
pinned-agents line 9: legal-clerk is already pinned by an earlier line
pinned-agents line 10: expected <rank 1-99> <self|secondmate-id> <host> <label>
pinned self fm-lab-pins-97740-22828:w1:p1
pinned legal-clerk fm-lab-pins-97740-22828:w1:p6
skipped tmuxmate: endpoint is on tmux, not herdr
pinned pbi fm-lab-pins-97740-22828:w1:p8
```

## noherdr  (exit 0)
```
herdr-absent
skipped self: herdr did not confirm the tokens
skipped view fm-lab-pins-97740-22828: herdr did not confirm the view
skipped legal-clerk: herdr did not confirm the tokens
skipped machinist: no endpoint record
skipped pbi: herdr did not confirm the tokens

real	0m0.504s
user	0m0.098s
sys	0m0.230s
```

## remote  (exit 0)
```
pinned self fm-lab-pins-97740-22828:w1:p1
skipped legal-remote: host 192.0.2.1 unreachable this pass
skipped pbi-remote: host 192.0.2.1 unreachable this pass

real	0m6.790s
user	0m0.113s
sys	0m0.124s
```

## remote255  (exit 0)
```
pinned self fm-lab-pins-97740-22828:w1:p1
skipped legal-remote: host fm-pins-nohost.invalid unreachable this pass
skipped pbi-remote: host fm-pins-nohost.invalid unreachable this pass

real	0m0.508s
user	0m0.116s
sys	0m0.103s
```

## spawn  (exit 0)
```
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fmhp-home.KMLW
WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.
warning: secondmate spawnmate sync skipped before launch: primary default-branch commit cannot be resolved
spawned spawnmate harness=sleep kind=secondmate mode=secondmate yolo=off window=fm-lab-pins-97740-22828:w2:p2 worktree=/private/tmp/fmhp-sub.yOC4
```

## teardown  (exit 0)
```
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fmhp-home.KMLW
WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.
teardown spawnmate complete (window fm-lab-pins-97740-22828:w2:p2, worktree /private/tmp/fmhp-sub.yOC4)
```

## pane tokens after first sync (agent list)
```
{"pane_id":"w1:p1","tokens":{"pin_host":"VPS","pin_label":"Firstmate","pin_rank":"01"}}
{"pane_id":"w1:p2","tokens":{"pin_host":"Mac","pin_label":"Legal Clerk","pin_rank":"02"}}
{"pane_id":"w1:p3","tokens":{"pin_host":"Mac","pin_label":"Machinist","pin_rank":"03"}}
{"pane_id":"w1:p4","tokens":{"pin_host":"WSL","pin_label":"Power BI","pin_rank":"05"}}
{"pane_id":"w1:p5","tokens":null}
```

## raw agent.view.set exchange with the lab server
```
request:  {"id":"fm-herdr-pins","method":"agent.view.set","params":{"source":"firstmate:pins","label":"Pinned","filter":{"op":"exists","field":{"token":"pin_rank"}},"sort":[{"field":{"token":"pin_rank"},"order":"asc"}]}}
response: {"id":"fm-herdr-pins","result":{"type":"agent_view","active":true,"source":"firstmate:pins","label":"Pinned"}}
```

## focused pane before/after prefix+alt+3 in a real client: w1:p1 -> w1:p3 (Machinist, rank 03)

## targeted tests
```
ok - with no config the helper is a silent no-op
ok - sync accepts the documented shape and names every rejected line
ok - sync pins self, local, and remote agents on their current endpoints and skips the rest
ok - sync is idempotent
ok - each pass resolves the current pane rather than a stored one
ok - a single-id sync pins only that agent
ok - self is skipped when this firstmate is not on Herdr
ok - an unreachable or missing Herdr never fails the pass
ok - an unreachable remote host costs one bounded call per pass
ok - clear removes the tokens of an agent the config pins and ignores the rest
ok - the remote pin and unpin verbs act on the host's own endpoint record
ok - the liveness tick re-asserts on its own cadence and session start always does
ok - the agent-view transport sends only the fixed view request
ok - watch liveness: the Herdr pin pass runs only on ticks that do not wake
```
