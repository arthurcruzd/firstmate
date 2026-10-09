# T3 Code runtime backend

T3 Code is an experimental, explicit-only backend in which a T3 Code server owns each worker's agent session as a durable thread.
Firstmate reaches it only through T3's Orchestrator V2 `/mcp` endpoint, while Treehouse still owns the task worktree the thread is bound to.
It runs ship and scout workers, on Claude or Codex, at full access.

T3 is a session manager in the same slot as tmux, Herdr, and Orca, not a second command surface.
The captain can watch or type into a worker's thread in T3's own UI exactly as into a Herdr pane, and Firstmate treats that as direct intervention in a worker window.
Firstmate remains the one interface for dispatching, steering, and landing work.

## Setup

Prerequisites:

- A T3 Code server that passes the capability gate below; the verified version is recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code).
  T3 stable 0.0.45 lacks the thread tools, so it is refused.
- `node` and `treehouse`, plus the universal toolchain in [`configuration.md`](configuration.md#toolchain).
- The Claude Code and Codex logins T3 itself uses on the machine it runs on.

Run the server that hosts Firstmate workers with T3's product telemetry off, so worker turns are not counted:

```sh
T3CODE_TELEMETRY_ENABLED=false t3 serve --host 127.0.0.1 --port <port> --no-browser
```

Every spawn reports the server's telemetry state and warns unless the listening loopback server's own process proves it off.
Stop the server through its own service or its native process id, never by pattern: a SIGTERM to the npm launcher leaves the native server running.

T3 binds a thread only to a linked worktree of the project clone it registered, and Treehouse keys its pools by repository identity, so two homes on one machine that clone the same remote share one pool by default.
A spawn refuses, and returns the lease of, a slot that belongs to another clone.
Give each extra home's clones their own pool with a git-excluded `treehouse.toml` whose `root =` names a directory only that home uses.

Select the backend with local `config/backend` containing `t3`, `FM_BACKEND=t3`, or an explicit per-task `--backend t3`.
It is never auto-detected.

### Sign-in

Issuing a full-access agent credential is the captain's decision, so the captain runs the sign-in and Firstmate never does:

```sh
bin/fm-t3-mcp.mjs login --url http://127.0.0.1:<port> --access full-access
```

Add `--t3 <path>` when `t3` is not on `PATH`, and `--base-dir <dir>` when the server runs with a non-default T3 base directory.
The sign-in mints a two-minute one-time pairing code with the operator's own `t3 auth pairing create`, scoped to `orchestration:read` and `orchestration:operate`, and spends it to approve Firstmate as an OAuth `mcp-client` at the full-access ceiling.
No browser is involved, and the token and pairing code are never printed.

Full access is required because a worker writes its status lines outside its worktree.
Under T3's narrower modes Codex's sandbox blocks that write and Claude parks on an approval that an MCP client cannot grant.
The credential is still much narrower than T3's administrative bearer from `t3 auth session issue`, which Firstmate does not use.

The credential, the server's origin, its environment id, and its version are written only to local, gitignored `config/t3-token`, mode 0600.
A secondmate home never inherits it.

### Expiry and revocation

T3 issues the credential for 30 days with no refresh token.
Every call warns within five days of expiry and refuses once it has expired; the captain then signs in again.

The credential appears in `t3 auth session list` as subject `mcp-client` with label `firstmate`.
Revoke it with `t3 auth session revoke <id>` and delete `config/t3-token` when retiring the backend.
A revoked credential is refused as unauthorized.

### Capability gate

Every helper call first runs `tools/list` and refuses unless T3 offers `t3_thread_launch`, `t3_thread_send`, `t3_thread_read`, `t3_thread_wait`, `t3_thread_interrupt`, `t3_thread_organize`, `t3_project_list`, `t3_project_create`, and `t3_environment_read`.
It then refuses unless `t3_environment_read` reports the environment id recorded at sign-in, so a different T3 server behind the same address is never driven with this credential.
Spawn and teardown run the gate before their first mutation, and a refusal names the missing tool or the mismatched environment.

## Task shape and metadata

Each task has one Treehouse slot and one T3 thread bound to it.

```text
backend=t3
window=fm-<id>
t3_origin=<server origin>
t3_environment_id=<environment id>
t3_project_id=<T3 project id>
t3_thread_id=<T3 thread id>
t3_provider_instance=claudeAgent|codex
t3_model=<model id>
```

`window=` is the caller-facing alias.
The backend target is `<t3_thread_id>@<t3_environment_id>`, so every call for the task is bound to the server it was spawned on.
`bin/fm-t3-mcp.mjs` owns the transport and `bin/backends/t3.sh` owns the primitives; their headers own exact commands and result shapes.

## Lifecycle

Spawn takes a durable Treehouse lease on a slot, claims it like a pane-acquired slot, and registers the project root with T3 once.
It then creates an idle thread bound to that existing worktree at full access, reads the binding back, and archives and refuses a thread T3 bound anywhere else.
Only after the task record is published does it send the launch brief as the thread's first message, under a request id that makes a retried delivery the same message.
A Claude worker receives the same record-backed launch doorbell a Claude pane does, and a Codex worker receives the encoded envelope.
A spawn that fails before T3 accepts the brief archives the thread and returns the lease; a thread whose archive cannot be proven keeps its slot leased.

The `claude` harness runs on T3's built-in `claudeAgent` instance and `codex` on its `codex` instance.
A `default` model is the instance's first catalog model.
Effort becomes that model's own effort option, and an effort the model does not offer is omitted with a warning.
T3's Claude reads the worktree's `.claude/settings.local.json`, so Firstmate's Claude busy and turn-end hooks fire there, and the no-agent-trailer attribution policy rides that file.

`fm-peek.sh` renders the thread's activity as a bounded text tail.
An `fm-send.sh` steer becomes the usual durable inbox record, and its doorbell is one thread message naming the inbox by its absolute path.
That message starts an idle thread's next turn or steers the running one.
The composer always reads empty, and Enter and Ctrl+U are accepted no-ops.
Escape, Ctrl+C, and `fm-control.sh <id> interrupt` interrupt the running turn natively, and T3's own wait on the run reports `cancel=confirmed`, `not-running`, or `unconfirmed`.

Teardown keeps every shared landed-work refusal.
Once they pass, it archives the thread and requires T3 to read back `archived:true` with no active run before any worktree process is reaped or the slot returns to the pool.
A close that is not proven, or a T3 that is unreachable or fails the gate, stops cleanup with every record and the leased slot intact, even under `--force`, because a live thread bound to a returned slot would act on whatever task leases it next.
Archived threads stay in T3, can be unarchived there, and are never deleted.

## What this backend refuses

- `--secondmate` spawns.
- Raw launch commands, and any harness other than `claude` and `codex`.
- A worker account pin, `config/claude-permission-mode` other than `bypass`, and `config/launch-env-allowlist`, none of which a T3-started agent can honor.
- `fm-control.sh exit` and `relaunch`, because T3 thread state is not yet a recovery-grade agent-state classifier.
- A server that fails the capability gate, and a credential that is missing, expired, revoked, readable by others, or from another environment.

## Known gaps

These are follow-up work, not current behavior:

- Per-task environment.
  T3 starts every provider from its own server environment, so `FM_TASK_ID`, `FM_TASK_INBOX`, `GOTMPDIR`, `TRACEPARENT`, `COMPACT_ADVISER_DISABLE`, `LAVISH_AXI_HOST`, and the commit-message trailer hook never reach a T3 worker.
  Claude's no-agent-trailer policy is covered by its settings file; a Codex worker's commits are not stripped.
- Semantic supervision.
  There is no backend busy source, watcher push, approval polling, wedge alarm, recovery-grade thread state, or restart reconciliation yet.
  A T3 server restart cancels in-flight runs, so a worker whose turn ended without a terminal status line needs a steer.
- T3 checkpoints each turn as hidden refs under `refs/t3/orchestration-v2/checkpoints/` in the project clone; they are never pushed and do not affect the landed-work test.
- Never point T3's own worktree directory at the Treehouse pool.

The Firstmate wiring shape follows the upstream proposal in https://github.com/kunchenguid/firstmate/pull/5596: explicit-only selection, the durable lease with archive-then-return on abort, the proven close before the slot returns, and the permission-mode, launch-environment, and account-pin refusals.
Its HTTP dispatch and shell write path, administrative bearer, WebSocket event stream, and secondmate paths are not used, because T3 0.0.46 removed that write route in favor of `/mcp`.

## Regression entry points

```sh
tests/fm-t3-mcp.test.sh
tests/fm-backend-t3.test.sh
tests/fm-t3-live-e2e.test.sh
```

The first two run against a fake T3 server and fake Treehouse.
The live guard spends no model tokens and changes nothing on the server; it reads this checkout's `config/t3-token` or `FM_T3_LIVE_TOKEN_FILE` and skips cleanly without one.
[`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code) records the live lifecycle evidence.
