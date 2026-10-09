Mode: T3 wake-relay supervision (this primary runs as a T3 Code thread).

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. The wake relay (`bin/fm-t3-host.sh relay`, run by a user service outside this session) owns watcher arm and re-arm, never you.
   T3 can unload an idle session, so nothing that supervises this home may live inside it; the Claude Stop auto-arm stands down while the relay owns the home.
3. A wake arrives as an ordinary thread message that starts with `Firstmate wake from the T3 wake relay:` and carries the watcher's reason lines (`signal:`, `stale:`, `check:`, or `heartbeat`).
   Run `bin/fm-wake-drain.sh` first and handle the wake, exactly as for any other wake.
   Do not run `bin/fm-watch-arm.sh` after a wake; the relay re-arms as soon as it has delivered one.
   When the wake says T3 reopened the session, run `bin/fm-session-start.sh` before draining: T3 reopens an unloaded session without its SessionStart hooks, so the session lock still names the dead process until session start runs.
4. Ending a turn with work in flight is safe while the relay is live: the turn-end guard accepts the relay's fresh watcher beacon.
   If the guard reports supervision off, check `bin/fm-t3-host.sh status` and the relay's service, and report a dead relay rather than arming a watcher from this session.
5. Waiting on the relay is silent: do not send idle progress while the watcher is parked.

In away or quiet mode the relay delivers no wakes and runs the away daemon itself: enter the mode through the `/afk` or `/quiet` skill as usual, and when `bin/fm-afk-launch.sh start-native` says the relay runs the daemon, do not start `bin/fm-afk-start.sh` in this session.
The daemon's escalations then arrive as away-supervisor messages; handle them under that skill.
