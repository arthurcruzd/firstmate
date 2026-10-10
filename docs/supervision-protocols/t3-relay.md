Mode: T3 wake-relay supervision (this primary runs as a T3 Code thread).

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. The wake relay (`bin/fm-t3-host.sh relay`, run by a user service outside this session) owns watcher arm and re-arm, never you.
   T3 can unload an idle session, so nothing that supervises this home may live inside it; the Claude Stop auto-arm stands down while the relay owns the home.
{t3-host}    Here the relay runs the supervision host (`config/supervision-host-off` turns it off; [`supervision-host.md`](../supervision-host.md) owns the design): a headless supervision session outside this thread takes the wakes the supervision branch may take, also while T3 has this session unloaded, and never wakes you for a routine outcome.
3. A wake arrives as an ordinary thread message that starts with `Firstmate wake from the T3 wake relay:` and carries the watcher's reason lines (`signal:`, `stale:`, `check:`, or `heartbeat`).
   Run `bin/fm-wake-drain.sh` first and handle the wake, exactly as for any other wake.
   Do not run `bin/fm-watch-arm.sh` after a wake; the relay re-arms as soon as it has delivered one.
   When the wake says T3 reopened the session, run `bin/fm-session-start.sh` before draining: T3 reopens an unloaded session without its SessionStart hooks, so the session lock still names the dead process until session start runs.
{t3-host}    Check wakes, decision wakes, and whatever the supervision session cannot take reach you this way, sometimes with a `supervision-host:` line saying why the wake is yours; a health note about repeated engine errors is worth telling the captain when it matters.
{t3-host}    A message that starts with `Firstmate supervision outcome from the T3 wake relay:` lists captain outcomes the supervision session recorded while handling a wake: run `bin/fm-wake-drain.sh`, process each entry of its `BRANCH OUTCOMES` section as firstmate from the task's current state (tell the captain, land or merge what is ready, answer or escalate a decision, or act on a blocker; your reply covers only entries still open), then run the `mark-processed` acknowledgement it prints; every drain presents them again until you do.
{t3-host}    Routine outcomes never reach you; your next drain lists visible ones under `BRANCH OUTCOMES, ROUTINE` for awareness, with nothing to acknowledge.
{t3-host}    A guarded command that exits 6 naming the branch actor's lease means the supervision session is handling that task right now: leave the lease alone and retry after it releases.
4. Ending a turn with work in flight is safe while the relay is live: the turn-end guard accepts the relay's fresh watcher beacon.
   If the guard reports supervision off, check `bin/fm-t3-host.sh status` and the relay's service, and report a dead relay rather than arming a watcher from this session.
5. Waiting on the relay is silent: do not send idle progress while the watcher is parked.

{t3-plain} In away or quiet mode the relay delivers no wakes and runs the away daemon itself: enter the mode through the `/afk` or `/quiet` skill as usual, and when `bin/fm-afk-launch.sh start-native` says the relay runs the daemon, do not start `bin/fm-afk-start.sh` in this session.
{t3-plain} The daemon's escalations then arrive as away-supervisor messages; handle them under that skill.
{t3-host} `/afk` writes only the away record here: the relay's supervision session is the away session, so only a wake it hands back reaches you, and the captain outcomes it records wait for the return drain ([Captain outcomes](../supervision-host.md#captain-outcomes)).
{t3-host} For `/quiet`, follow the [quiet skill](../../.agents/skills/quiet/SKILL.md): where `bin/fm-afk-launch.sh quiet-check` says quiet mode needs nothing, the supervision session already keeps routine wakes off this thread; otherwise the relay runs the quiet daemon, whose escalations arrive as away-supervisor messages to handle under that skill, and when `bin/fm-afk-launch.sh start-native` says the relay runs the daemon, do not start `bin/fm-afk-start.sh` in this session.
