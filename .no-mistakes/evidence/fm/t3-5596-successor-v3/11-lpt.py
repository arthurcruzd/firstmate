import sys
hints_f, lane_f, runner_f = sys.argv[1:4]
hints = {}
for line in open(hints_f):
    p = line.split()
    if len(p) == 2 and p[1].isdigit(): hints[p[0]] = int(p[1])
lane = [l.strip() for l in open(lane_f) if l.strip()]
runner = {}
for line in open(runner_f):
    k, s = line.rstrip("\n").split("\t"); runner[s] = int(k)
def pack(over):
    w = {s: over.get(s, hints.get(s, 45000)) for s in lane}
    order = sorted(lane, key=lambda s: (-w[s], s.encode()))
    loads = [0]*9; assign = {}
    for s in order:
        b = min(range(9), key=lambda i: (loads[i], i)); loads[b] += w[s]; assign[s] = b+1
    return loads, assign, sum(w.values())
loads, assign, total = pack({})
mism = [s for s in lane if assign[s] != runner.get(s)]
print(f"real hints: lane scripts={len(lane)} total_ms={total} nine-shard capacity=10800000 max_shard_ms={max(loads)} budget=1200000 -> {'ok' if max(loads)<=1200000 else 'OVER'}; reimplementation matches the runner's own shard listing for {len(lane)-len(mism)}/{len(lane)} scripts")
print("  shard loads:", loads)
for wt in (1200000, 1200001):
    loads, _, total = pack({"tests/fm-watch-triage.test.sh": wt})
    print(f"boundary fixture (fm-watch-triage hint {wt}): total_ms={total} max_shard_ms={max(loads)} -> {'accepted' if max(loads)<=1200000 else 'refused'} (expected: {'accepted, serial_max_ms=1200000' if wt==1200000 else 'refused, 1200001ms'})")
    print("  shard loads:", loads)
