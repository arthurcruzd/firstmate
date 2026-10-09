# T3 Code runtime backend

T3 Code is an experimental backend in which the T3 Code server owns the agent session while Treehouse keeps owning the task worktree.
Firstmate drives the server only through its Orchestrator V2 `/mcp` endpoint, signed in as an OAuth `mcp-client`, and nothing is typed into a terminal.
[`bin/fm-t3-mcp.mjs`](../bin/fm-t3-mcp.mjs) owns that transport, the credential, and the capability gate; [`bin/backends/t3code.sh`](../bin/backends/t3code.sh) owns the backend primitives built on it.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick T3 Code when you already run the T3 Code app and want each task to be a visible T3 thread working in a Treehouse worktree, and each secondmate a visible T3 thread working in its own home.
T3 Code runs only the `claude` and `codex` harnesses; every other harness is refused at spawn.

Prerequisites:

- A running T3 Code server that passes the [capability gate](#capability-gate).
  T3 stable 0.0.45 lacks the Orchestrator V2 thread tools, so it is refused; the verified version is recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code).
- `node`, which the adapter uses to speak MCP, and `treehouse`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Run the server that hosts Firstmate workers with T3's product telemetry off, so worker turns are not counted:

```sh
T3CODE_TELEMETRY_ENABLED=false t3 serve --host 127.0.0.1 --port <port> --no-browser
```

Every spawn and control action reports the server's telemetry state and warns unless the listening loopback server's own process proves it off.

Select T3 Code with local `config/backend` containing `t3code`, `FM_BACKEND=t3code` for one launch, or `--backend t3code` for one task.
T3 Code is explicit-only for task dispatch; a configured server does not select this backend automatically.
An explicitly configured T3 home can identify its active supervisor by its home thread.
The shared selection rules and precedence are in [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend).
The [capability gate](#capability-gate) applies before spawn, control, or teardown mutations.

### Sign-in

Issuing a full-access agent credential is the captain's decision, so the captain runs the sign-in and Firstmate never does:

```sh
bin/fm-t3-mcp.mjs login --access full-access
```

The server origin defaults to `FM_T3CODE_ORIGIN`, else the `origin` in `~/.t3/userdata/server-runtime.json`; `--url <origin>` names it explicitly.
Add `--t3 <path>` when `t3` is not on `PATH`, and `--base-dir <dir>` when the server runs with a non-default T3 base directory.
The sign-in mints a two-minute one-time pairing code with the operator's own `t3 auth pairing create`, scoped to `orchestration:read` and `orchestration:operate`, and spends it to approve Firstmate as an OAuth `mcp-client` at the full-access ceiling.
No browser is involved, and the token and pairing code are never printed.

Full access is required because a worker writes its status lines outside its worktree.
Under T3's narrower modes Codex's sandbox blocks that write and Claude parks on an approval that an MCP client cannot grant.
The credential is much narrower than T3's administrative bearer from `t3 auth session issue`, which this backend no longer uses; T3 accepts an `mcp-client` session only on `/mcp`.

The credential, the server's origin, its environment id, and its version are written to the local, gitignored `config/t3code-token`, mode 0600.
A missing, expired, revoked, or over-readable credential refuses with one error that names the sign-in command.
A secondmate spawned on this backend gets `config/t3code-token` as a symlink to the primary's credential file, so its own daemon and crew use the same credential without a copy of the secret, and a fresh sign-in reaches them.

### Expiry and revocation

T3 issues the credential for 30 days with no refresh token.
Every call warns within five days of expiry and refuses once it has expired; the captain then signs in again.
The credential appears in `t3 auth session list` as subject `mcp-client` with label `firstmate`.
Revoke it with `t3 auth session revoke <id>` and delete `config/t3code-token` when retiring the backend.

### Provider instances and models

`config/t3code-instances` maps a harness to a T3 provider instance id, one `harness=instanceId` line each; the defaults are `claude=claudeAgent` and `codex=codex`.
The file is part of the primary's inherited local material, so every secondmate home receives the primary's mapping and its own T3 workers launch on the same provider instances; a home without the file falls back to those bare defaults, which need not name a configured account.
A task's `--model` must be a slug in T3's model catalog.
`--model default` uses the T3 project's default model only when its instance matches `config/t3code-instances`; otherwise it refuses and asks for an explicit `--model`.
`--effort` rides as a provider option, `effort` for claude (`low|medium|high|xhigh|max`) and `reasoningEffort` for codex (`low|medium|high|xhigh`); a value outside a harness's set is refused.
With `--effort default`, `--model default` preserves the project's default options, while an explicit model sends no options.

### Capability gate

Every call first runs `tools/list` and refuses unless T3 offers `t3_thread_launch`, `t3_thread_send`, `t3_thread_read`, `t3_thread_wait`, `t3_thread_interrupt`, `t3_thread_organize`, `t3_project_list`, `t3_project_create`, and `t3_environment_read`.
It then refuses unless `t3_environment_read` reports the environment id recorded at sign-in, so a different T3 server behind the same address is never driven with this credential.
A refusal names the missing tool or both environment ids, and spawn, control, and teardown stop before their first mutation.
This gate replaces the HTTP dispatch probe and version floor of the pre-V2 transport, which T3 0.0.46 removed.

## Task shape and metadata

Each ship or scout task has one Treehouse worktree, leased durably with `treehouse get --lease --lease-holder <id>`, and one T3 thread launched with the `existing_worktree` workspace strategy on that worktree.
A secondmate's T3 project is its home and its thread is launched with the `root` workspace strategy, so the agent runs in the home on whatever branch the home is on.
T3 assigns the thread id at launch (`mcp:<uuid>`), and the task records it as `t3_thread_id`.
The normal isolation and unlanded-work refusal rules still apply.

[`configuration.md`](configuration.md#task-metadata) owns the task metadata fields, and its [task-selector contract](configuration.md#task-selectors) owns routing to the recorded thread.

## Per-directory harness environment

T3 sets environment variables per provider instance, never per thread, so nothing can be typed into a pane before launch.
Each harness reads its own configuration from the thread's working directory instead, and Firstmate writes the facts a pane would have exported into that directory before the launch turn.
For `claude` that is an `env` block in the directory's `.claude/settings.local.json`, merged alongside the busy hooks a worker already carries there; for `codex` it is a `.codex/config.toml` holding a `[shell_environment_policy]` `set` table.
Firstmate-created untracked environment files are git-excluded and removed at teardown.
An existing untracked `.codex/config.toml` without Firstmate's marker is preserved and refused.
For a tracked `.codex/config.toml`, Firstmate preserves the project bytes and appends its policy only if the file does not already define `shell_environment_policy`, including through dotted or quoted keys.
`bin/fm-t3code-codex-env.sh` owns the tracked overlay, its private worktree Git journal, and its `skip-worktree` protection against ordinary staging and commits.
Teardown restores the original bytes and prior Git flag before returning the slot; unexpected file or index edits refuse cleanup and retain the journal for recovery.
The tracked path requires Python 3.11 or newer for TOML parsing; the script uses the first of `python3`, `python3.14`, `python3.13`, `python3.12`, or `python3.11` on `PATH` that imports `tomllib`, and refuses before any mutation when none does.
Codex's [configuration layers](https://learn.chatgpt.com/docs/config-file/config-basic#configuration-precedence) provide no separate per-directory fragment for a thread launched at the repository root, and T3 cannot select a different CLI override or profile per thread.
Every kind receives `GOTMPDIR`, `COMPACT_ADVISER_DISABLE=1`, and `FM_TASK_INBOX`, plus `LAVISH_AXI_HOST` when `config/lavish-axi-host` is set; ship and scout workers also receive `FM_TASK_ID`; `TRACEPARENT` rides only when trace context is on, and only once its `traceparent=` line is recorded.
A secondmate additionally receives the launch prefix every other backend types (`FM_ROOT_OVERRIDE`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` empty, `FM_PUBLIC_FOLLOWUP_PRIMARY_HOME`, `FM_HOME`, `FM_TRACE_CONTEXT`, `FM_SUPERVISION_MODEL`) plus `FM_SUPERVISOR_BACKEND=t3code` and its own thread id as `FM_SUPERVISOR_TARGET`, so its away daemon resolves its target exactly.
A `claude` ship or scout worker also receives the task-worker channel statement that a pane launch appends to the system prompt, written as a `CLAUDE.local.md` in its worktree because T3 owns the system prompt; a secondmate does not, as on every backend.
Without it a Claude worker can refuse the launch brief as prompt injection, which happened live.
The statement also tells the worker not to call T3's `link_pull_request`, `list_thread_pull_requests`, or `unlink_pull_request` tools even when host instructions request it, because those calls crash Claude's session and Firstmate already records the PR from the worker's `done: PR <url>` status line.
A `claude` task checks the leased worktree and refuses a tracked, existing, or symlinked `CLAUDE.local.md`, because that file is the backend's channel and teardown removes it.

## Current lifecycle and safety

Spawn matches the project (the home, for a secondmate) by real path against T3's live projects, creating one titled `fm-<directory name>` with `t3_project_create` when absent, and leases the worktree for a worker.
It then launches an idle thread with `t3_thread_launch` (the workspace strategy and branch, `full-access` runtime mode, the model selection) and reads the thread back; a thread T3 bound to another workspace, provider instance, or runtime mode is archived and the spawn refuses.
It installs the harness hooks, records metadata, installs the [per-directory harness environment](#per-directory-harness-environment), and sends the encoded brief (the charter, for a secondmate) as the thread's first message with `t3_thread_send`.
Exact call payloads are owned by `bin/fm-t3-mcp.mjs` and `bin/backends/t3code.sh`.

`fm-peek.sh` renders the thread's activity view as `[type/status] text` lines followed by a `t3code: status=<status> run=<active run>` line.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and its doorbell is a `t3_thread_send` in `auto` mode under a fresh request id, which starts an idle thread's next turn or steers the running one.
The submit primitive reports `empty` when T3 accepts the message, so the daemon can clear its delivery buffer; task completion remains a separate worker status event.
Escape and Ctrl-C are both a `t3_thread_interrupt` confirmed by T3's own `t3_thread_wait` on the run; Enter is a no-op and Ctrl-U is unsupported.

The control plane ([`agent-control.md`](agent-control.md)) reads the same status table.
`interrupt` is a `t3_thread_interrupt` proven by the thread still reading alive afterwards.
`exit` is refused before anything is sent: the V2 `/mcp` tools have no session stop, and an interrupt leaves the thread idle and alive, so no stop could be proven.
`relaunch` is refused before anything is stopped: a T3 thread is bound to the driver that first ran it, and a new turn continues the same agent, so no replacement agent can be launched into the endpoint.

The watcher and `fm-crew-state.sh` use the adapter's [thread status table](#restart-and-liveness-behavior) ahead of harness gates and hook records (source `t3code-native`), so a codex crew settles from T3's status even though codex has no verified hook writer.
Native uncertainty stays unknown instead of falling through to a hook record or rendered fallback.
Watcher re-rings for ordinary records treat that uncertainty like busy, so a due doorbell waits and spends the same busy-deferral budget [`bin/fm-task-inbox-lib.sh`](../bin/fm-task-inbox-lib.sh) owns before a stuck-busy escalation.
The initial `fm-send.sh` doorbell follows that library's best-effort ring contract instead.
A thread's capture stays byte-identical through a long tool call, so before reporting a possible wedge the watcher rechecks the [thread status table](#restart-and-liveness-behavior) and resets its stale timer only for the `running` word.
That deferral is itself bounded by `FM_BUSY_TURN_MAX_SECS`, measured from the latest run boundary T3 records (completion, or start while the run is still active), so a hung run still reaches the possible-wedge alert, and a missing run timestamp never defers.
`wedge_defer_t3code_running` in `bin/fm-watch.sh` owns that consult; all other classified words keep the ordinary escalation ladder, including its declared-wait, worktree-write, and dead-record checks.
T3 launches Claude with the `user,project,local` setting sources, so the worktree `.claude/settings.local.json` busy hooks fire as on every other backend.
T3 starts every agent with the T3 server's own environment, not a login shell's.
Codex runs each command through `/bin/zsh -lc` in that environment, so the Firstmate toolchain must survive the login shell's startup files, and a startup file that rebuilds `PATH` when a marker variable is missing hides it from every Codex worker; Claude's shell tool restores its own login-shell snapshot and is unaffected.
A remote secondmate is unaffected by this backend: it always runs on the remote host's Herdr, and `--backend t3code` on one is refused.

Cleanup keeps all shared Firstmate safety checks.
Before the slot returns to the pool, or before a secondmate home is removed, teardown interrupts any active run, archives the thread with `t3_thread_organize`, and requires T3 to read back `archived:true` with no active run, so no live thread can act in a slot another task may lease.
If spawn aborts after launching the thread, cleanup uses the same proven close and keeps the lease when it fails, then prints the manual archive and `treehouse return --force` steps.
`t3_thread_launch` has no idempotency key, so a launch whose response was lost leaves ownership uncertain: spawn keeps the lease, never retries, and names the slot to check in T3 Code before returning it.
The kill is idempotent, so an already archived thread, or one the verified server no longer has, is the end state, and an unreachable or gate-refused server refuses the teardown rather than returning a slot a live thread still points at.
Archiving keeps the transcript visible in T3 Code; this backend never deletes a thread.
The `fm-` project of a torn-down secondmate home stays in T3 Code pointing at the removed directory until the operator deletes it there, because deleting a nonempty project takes the archived thread's transcript with it.

## Restart and liveness behavior

The T3 thread id, transcript, provider binding, and Treehouse worktree outlive a server connection.
A server restart cancels in-flight runs even though the thread still exists, so a worker whose turn ended without a terminal status line needs a steer.
Thread persistence alone does not prove a live agent.

`bin/backends/t3code.sh` owns one status table over the thread's V2 status, read with `t3_thread_read`:

- `preparing`, `queued`, `starting`, `running`, and `waiting` (the run's post-turn drain) read busy/alive.
- `idle`, `completed`, `interrupted`, `cancelled`, and `rolled_back` read idle/alive.
- `failed` reads unknown/dead.
- An archived thread, or one the verified server does not have, reads missing.
- An unreachable server, a refused gate, or a failed read reads `unknown unreadable`, which is never treated as proof that a replacement agent is safe.

Inspect a failed worker's thread error before sending a new turn through its normal steer path.
A new turn continues the same driver and transcript; `fm-control.sh relaunch` remains refused.
Teardown still requires a proven archive before returning the worktree.

## Push events and polling fallback

T3 accepts an `mcp-client` session only on `/mcp`, so its WebSocket event stream is not available to this credential, and T3 windows stay on the watcher's poll loop at the existing cadence.
Pending approvals on a running thread therefore read busy rather than `blocked`.
An event-driven turn-end wait through `t3_thread_wait` is follow-up work.

## Firstmate itself in T3

A home's own primary session can run as a pinned T3 thread, so the captain talks to Firstmate in T3's UI, including T3's mobile app, while workers stay ordinary T3 threads.
`bin/fm-t3-host.sh` owns this: `launch` registers the Firstmate checkout as a T3 project, writes the home into the checkout's git-ignored `.claude/settings.local.json` as `FM_HOME`, and starts a full-access Claude thread on the project root, pinned; `adopt` records a thread started from T3's UI instead.
The checkout's tracked Claude hooks run inside the thread, so session start, the session lock, and the turn-end guard work as in a terminal.

T3 releases an idle provider session after 30 minutes, or after at most four hours while background work pins it, and a Stop-hook-owned watcher would die with it.
The home therefore runs the wake relay, `bin/fm-t3-host.sh relay`, as a user service (`bin/fm-t3-host.sh install` writes the systemd unit).
The relay owns the watcher outside the session and sends each actionable wake to the primary's thread as an ordinary message, which also reopens an unloaded session.
While a live relay owns the home the Claude Stop auto-arm stands aside, the turn-end guard accepts the relay's fresh beacon, and session start renders [`supervision-protocols/t3-relay.md`](supervision-protocols/t3-relay.md); in away or quiet mode the relay idles and the [away daemon](#away-mode) owns the watcher.
A T3 server restart ends the primary's session and cancels any running worker turn; the relay's next wake reopens the session, whose session start runs again, and a cancelled worker is recovered with one steer.

Treehouse keys its pools by repository identity, so two homes on one machine that clone the same remote share one pool by default, and T3 binds a thread only to a linked worktree of the clone it registered.
A spawn refuses, and returns the lease of, a slot that belongs to another clone; give each extra home's clones their own pool with a git-excluded `treehouse.toml` whose `root =` names a directory only that home uses.

<a id="away-mode"></a>

## Away-mode supervisor support

The away daemon can supervise a captain that runs inside a T3 thread.
[`configuration.md`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns discovery precedence and the explicit-selection and credential prerequisites.
T3 puts nothing about the thread into the agent's environment, so eligible discovery matches this home's real path to a live project's `workspaceRoot`, lists its threads with an active run through `t3_thread_list`, and selects the one unarchived thread with no worktree of its own.
Multiple matching threads print an ambiguity diagnostic naming their ids and fall through to the legacy tmux fallback, as do no matches or an unreachable server.
Resolve ambiguity by explicitly setting both `FM_SUPERVISOR_BACKEND=t3code` and `FM_SUPERVISOR_TARGET` to the intended thread id.
Busy uses the [thread status table](#restart-and-liveness-behavior), injection is a `t3_thread_send`, and escalations defer exactly as on every other backend.
An unknown native busy verdict defers new-turn delivery but does not prove that work resumed.
Away housekeeping keeps an overdue stale alert pending and buffers one possible-wedge report while the verdict remains unknown, including a failed run or a transient thread-read failure.
Delivered warnings stay suppressed while the same unknown condition persists.
If a fresh daemon entry discards a queued, undelivered warning, it clears that warning's reported marker and preserves its stale timer, so the next housekeeping pass queues exactly one replacement.
Refreshing a live daemon preserves the queue; a failed start restores the previous queue and reported markers.
Confirmed busy activity or a missing thread clears the stale and reported markers, so a later unknown condition can report again.
Declared external-wait rechecks also survive native uncertainty; the worker's declaration still controls their cadence.
`stale_window_is_busy` and `housekeeping` in `bin/fm-supervise-daemon.sh` own stale tracking; `fm_afk_clear_stale_artifacts` in `bin/fm-afk-start.sh` and the launcher in `bin/fm-afk-launch.sh` own queue discard and startup rollback.
`tests/fm-backend-t3code.test.sh` covers retention, deduplication, and re-arming across native restart.
Only `bin/fm-afk-launch.sh start-native` launches the daemon here, as the captain's own tracked background job; `start` refuses because T3 hosts no terminal to create.
A secondmate spawned on this backend carries its supervisor identity in its environment, so its own daemon needs no discovery.

## Switching back to Herdr

Write `herdr` to `config/backend` and every new spawn uses the Herdr backend again.
In-flight tasks keep the backend recorded in their own `state/<id>.meta`, so they are supervised and torn down through T3 Code until they finish.

## Moving a task from the pre-V2 transport

A home that used the earlier HTTP dispatch transport needs the `/mcp` credential first: run the [sign-in](#sign-in), which replaces the old bearer in `config/t3code-token`.
Whether T3 V2 still serves a thread created through that transport is unverified, so if a task's thread no longer reads back, release the task by hand:

1. Archive the task's thread in T3 Code.
2. For a worker, undo the per-worktree environment with `bin/fm-t3code-codex-env.sh cleanup <worktree>`, then remove `CLAUDE.local.md` and `.claude/settings.local.json` from the worktree.
   Skipping this hands the next holder of the slot a hidden `.codex/config.toml` overlay carrying the dead task's environment, and refuses the next T3 Codex spawn there.
   For a secondmate, release its own tasks in this same order, then run `bin/fm-t3code-codex-env.sh cleanup <home>` and remove its `.claude/settings.local.json` before releasing the home.
3. For a worker, return its slot with `treehouse return --force <worktree>` from its project.
   A secondmate has no separate task worktree, but its home may itself be leased: preserve its durable records and unlanded work, then return a pooled home with `treehouse return --force <home>` from the Firstmate code root, or remove a standalone home by hand.
   Remove its line from the parent's `data/secondmates.md`.
4. Remove the task record, `state/<id>.meta`, and its other `state/<id>.*` files.

## Active limits

- T3 Code remains experimental and runs only `claude` and `codex`.
- T3 starts the agent at `full-access` with its provider instance's account and environment, so a spawn refuses `config/claude-permission-mode=auto` for `claude`, `config/launch-env-allowlist`, and a worker account pin; select the account through `config/t3code-instances` instead.
- T3 owns the Claude provider command, so Firstmate cannot add its command-line prompt-suggestion, feedback-draft, or attribution controls; configure equivalent provider-instance settings in T3 when those policies are required.
  Unless `config/keep-ai-trailers` is present, the per-worktree environment selects Firstmate's Git commit hook to strip known AI trailers, including on T3 workers.
- T3 also owns the Codex provider command, so Firstmate cannot apply the pane-backed worker's hook-disable or turn-end notify options.
  Firstmate's pane-backed hook-trust workaround therefore does not apply; supervision uses T3's [thread status table](#restart-and-liveness-behavior).
- `fm-control.sh exit` is refused because the V2 `/mcp` tools have no session stop, and `relaunch` is refused because a thread is bound to its existing driver.
- There is no push stream for an `mcp-client` credential, so T3 windows are polled.
- A tracked `.codex/config.toml` that already defines `[shell_environment_policy]` is refused by file and table name before a slot is leased.
- While a tracked Codex overlay is installed, do not edit that file or clear its `skip-worktree` flag; configuration changes require cleanup first.
- Shell typing and Ctrl-U are unsupported; runtime Escape and Ctrl-C still interrupt the turn.
- A Codex supervisor has no away mode on this backend because it has no tracked background tool for `start-native`, and T3 has no terminal for `start` to create.
- T3 checkpoints each turn as hidden refs under `refs/t3/orchestration-v2/checkpoints/` in the project clone; they are never pushed and do not affect the landed-work test.

## Regression entry points

```sh
bin/fm-test-run.sh tests/fm-t3-mcp.test.sh tests/fm-backend-t3code.test.sh
bin/fm-test-run.sh tests/fm-backend.test.sh tests/fm-daemon.test.sh tests/fm-control.test.sh
FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-live-e2e.test.sh
```

The first two run against a fake T3 `/mcp` server ([`tests/t3-fake-server.mjs`](../tests/t3-fake-server.mjs)) and a fake Treehouse.
The live guard spends no model tokens and changes nothing on the server: it checks the gate, the project catalog, and a typed missing-thread read against the server the configured credential names, and skips cleanly without one.
Set `FM_T3CODE_LIVE_E2E=0` to disable it or `FM_T3CODE_LIVE_E2E=1` to require it; the shared `FM_LIVE` override also applies.
[`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code) records the dated live results.
