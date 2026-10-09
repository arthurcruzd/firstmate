#!/usr/bin/env node
// tests/t3-fake-server.mjs - a fake T3 Code server for the t3code backend
// suites (tests/fm-t3-mcp.test.sh, tests/fm-backend-t3code.test.sh).
//
// It serves T3's headless OAuth sign-in (/oauth/mcp/register, /decision,
// /token) and the Orchestrator V2 `/mcp` streamable-HTTP endpoint with the
// tool subset bin/fm-t3-mcp.mjs drives. Shapes follow T3 0.0.46 nightly as
// recorded in docs/verification/runtime-backends.md.
//
// Usage: t3-fake-server.mjs --case-file <file> --port-file <file> [--parent-pid <pid>]
// <case-file> holds the path of the current case directory. Every request
// re-reads <case-dir>/world.json, writes it back after a mutation, and appends
// one JSON line to <case-dir>/requests.jsonl, so a test can switch cases and
// edit the world between calls. World keys (all optional):
//   tokens (accepted bearers; sign-in appends), environmentId, serverVersion,
//   tools (array of names; default all), revoked (every /mcp call is 401),
//   sse (SSE replies), expiresIn (seconds), bindWorktree, bindInstance,
//   bindRuntimeMode (override what a launch binds), archiveKeepsRun,
//   waitTimesOut, waitEnds (a t3_thread_wait on an active run ends it with
//   this status), failTools ({name: {code, message}}), dropTools ({name:
//   count}: close the connection without a reply that many times), probePath
//   (each log line records whether it exists), projects ([{id, title,
//   workspaceRoot, defaultModelSelection, deletedAt}]), threads ({id: detail
//   plus items and runs}).

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].slice(2)] = process.argv[i + 1];

const ALL_TOOLS = [
  "t3_thread_launch", "t3_thread_send", "t3_thread_read", "t3_thread_wait", "t3_thread_interrupt",
  "t3_thread_organize", "t3_thread_list", "t3_thread_configure", "t3_project_list", "t3_project_create",
  "t3_environment_read",
];
const ACTIVE = new Set(["preparing", "queued", "starting", "running", "waiting"]);

const caseDir = () => readFileSync(args["case-file"], "utf8").trim();
const worldFile = () => path.join(caseDir(), "world.json");
const loadWorld = () => {
  try {
    return JSON.parse(readFileSync(worldFile(), "utf8"));
  } catch {
    return {};
  }
};
const saveWorld = (w) => writeFileSync(worldFile(), JSON.stringify(w));
const log = (w, entry) => {
  if (w.probePath) entry.probe = existsSync(w.probePath);
  appendFileSync(path.join(caseDir(), "requests.jsonl"), `${JSON.stringify(entry)}\n`);
};

const clients = new Map();
const codes = new Map();

function body(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => resolve(data));
  });
}

function json(res, status, obj, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(obj));
}

const err = (code, message) => ({ isError: true, structuredContent: { error: { code, message } }, content: [{ type: "text", text: message }] });
const ok = (data) => ({ structuredContent: data, content: [{ type: "text", text: JSON.stringify(data) }] });
const now = () => new Date().toISOString();

function detail(t) {
  const { items, runs, ...rest } = t;
  return rest;
}

function startRun(t, text) {
  const runId = `run:${randomUUID()}`;
  t.runs = t.runs ?? [];
  t.runs.unshift({ runId, ordinal: t.runs.length + 1, status: "running", requestedAt: now(), startedAt: now(), completedAt: null });
  t.activeRunId = runId;
  t.latestRunId = runId;
  t.status = "running";
  t.items = t.items ?? [];
  t.items.push({ type: "user_message", status: "completed", text });
  return runId;
}

function endRun(t, status) {
  const run = (t.runs ?? []).find((r) => r.runId === t.activeRunId);
  if (run) {
    run.status = status;
    run.completedAt = now();
  }
  t.activeRunId = null;
  t.status = status;
}

const notFound = (id) => err("thread_not_found", `Thread ${id} is no longer available.`);

// Returns [result, changed].
function callTool(w, name, a) {
  const fail = (w.failTools ?? {})[name];
  if (fail) return [err(fail.code, fail.message), false];
  const threads = (w.threads = w.threads ?? {});
  const projects = (w.projects = w.projects ?? []);
  const t = a.threadId !== undefined ? threads[a.threadId] : undefined;
  switch (name) {
    case "t3_environment_read":
      return [ok({ environmentId: w.environmentId ?? "env-fake-1", serverVersion: w.serverVersion ?? "0.0.46-nightly.fake" }), false];
    case "t3_project_list":
      return [ok({ projects, nextCursor: null }), false];
    case "t3_project_create": {
      if (projects.some((p) => !p.deletedAt && p.workspaceRoot === a.workspaceRoot)) return [err("invalid_request", "workspace already registered"), false];
      const p = { id: `mcp:proj-${randomUUID()}`, title: a.title, workspaceRoot: a.workspaceRoot, defaultModelSelection: null, deletedAt: null };
      projects.push(p);
      return [ok(p), true];
    }
    case "t3_thread_launch": {
      const ws = a.workspaceStrategy ?? {};
      const id = `mcp:${randomUUID()}`;
      const n = {
        threadId: id, projectId: a.projectId, title: a.title, status: "idle", latestRunId: null, activeRunId: null,
        providerInstanceId: w.bindInstance ?? a.modelSelection?.instanceId, model: a.modelSelection?.model,
        runtimeMode: w.bindRuntimeMode ?? a.runtimeMode, interactionMode: a.interactionMode,
        branch: ws.branch ?? null, worktreePath: w.bindWorktree ?? (ws.type === "existing_worktree" ? ws.worktreePath : null),
        parentThreadId: null, pendingRequestCount: 0, archived: false, items: [], runs: [],
      };
      threads[id] = n;
      if (a.message) startRun(n, a.message);
      return [ok({ threadId: id, projectId: n.projectId, runId: n.activeRunId, status: n.status }), true];
    }
    case "t3_thread_send": {
      if (!t) return [notFound(a.threadId), false];
      if (t.archived) return [err("thread_not_sendable", `Thread ${a.threadId} is archived and cannot receive messages.`), false];
      w.requestIds = w.requestIds ?? {};
      const key = `${a.threadId}|${a.clientRequestId}`;
      if (a.clientRequestId && w.requestIds[key]) return [ok(w.requestIds[key]), false];
      let delivery = "steered";
      if (t.activeRunId) t.items.push({ type: "user_message", status: "completed", text: a.message });
      else {
        startRun(t, a.message);
        delivery = "started";
      }
      const out = { threadId: t.threadId, messageId: `msg:${randomUUID()}`, runId: t.activeRunId, status: "running", delivery };
      if (a.clientRequestId) w.requestIds[key] = out;
      return [ok(out), true];
    }
    case "t3_thread_read": {
      if (!t) return [notFound(a.threadId), false];
      const items = (t.items ?? []).slice(-(a.limit ?? 100));
      return [ok({ thread: detail(t), recentRuns: (t.runs ?? []).slice(0, a.runLimit ?? 5), items, nextPosition: null, hasMore: false }), false];
    }
    case "t3_thread_list": {
      const wanted = a.statuses ? new Set(a.statuses) : null;
      const list = Object.values(threads)
        .filter((x) => x.projectId === a.projectId && (!wanted || wanted.has(x.status)))
        .map((x) => ({ threadId: x.threadId, title: x.title, status: x.status, parentThreadId: x.parentThreadId ?? null }));
      return [ok({ projectId: a.projectId, currentThreadId: null, threads: list, nextCursor: null, total: list.length }), false];
    }
    case "t3_thread_wait": {
      if (!t) return [notFound(a.threadId), false];
      if (w.waitEnds && t.activeRunId && !w.waitTimesOut) {
        const runId = t.activeRunId;
        endRun(t, w.waitEnds);
        return [ok({ threadId: t.threadId, runId, status: t.status, timedOut: false }), true];
      }
      return [ok({ threadId: t.threadId, runId: t.activeRunId ?? null, status: t.status, timedOut: Boolean(w.waitTimesOut) }), false];
    }
    case "t3_thread_interrupt": {
      if (!t) return [notFound(a.threadId), false];
      if (!t.activeRunId) return [ok({ threadId: t.threadId, runId: null, status: "no_active_run" }), false];
      const runId = t.activeRunId;
      if (!w.waitTimesOut) endRun(t, "interrupted");
      return [ok({ threadId: t.threadId, runId, status: "interrupt_requested" }), true];
    }
    case "t3_thread_organize": {
      if (!t) return [notFound(a.threadId), false];
      if (a.action === "archive") {
        t.archived = true;
        if (!w.archiveKeepsRun && t.activeRunId) endRun(t, "interrupted");
      }
      if (a.action === "unarchive") t.archived = false;
      return [ok({ threadId: t.threadId, action: a.action }), true];
    }
    case "t3_thread_configure": {
      if (!t) return [notFound(a.threadId), false];
      const sel = a.modelSelection ?? {};
      if ((t.runs ?? []).length && sel.instanceId && sel.instanceId !== t.providerInstanceId) {
        return [err("invalid_request", `Thread ${a.threadId} is bound to driver '${t.providerInstanceId}' and cannot switch to '${sel.instanceId}'.`), false];
      }
      if (sel.instanceId) t.providerInstanceId = sel.instanceId;
      t.model = sel.model;
      return [ok({ sequence: 1 }), true];
    }
    default:
      return [err("unknown_tool", `no tool ${name}`), false];
  }
}

async function mcp(req, res) {
  const w = loadWorld();
  const auth = (req.headers.authorization ?? "").replace(/^Bearer /, "");
  const msg = JSON.parse(await body(req));
  const entry = { path: "/mcp", method: msg.method, tool: msg.params?.name, arguments: msg.params?.arguments, auth, protocol: req.headers["mcp-protocol-version"] };
  if (w.revoked || !(w.tokens ?? []).includes(auth)) {
    log(w, { ...entry, status: 401 });
    return json(res, 401, { error: "invalid_token" });
  }
  if (msg.method === "tools/call" && (w.dropTools ?? {})[msg.params.name] > 0) {
    w.dropTools[msg.params.name]--;
    saveWorld(w);
    log(w, { ...entry, dropped: true });
    return req.socket.destroy();
  }
  let result;
  if (msg.method === "initialize") {
    result = { protocolVersion: msg.params.protocolVersion, serverInfo: { name: "t3", version: w.serverVersion ?? "0.0.46-nightly.fake" }, capabilities: { tools: {} } };
  } else if (msg.method === "notifications/initialized") {
    log(w, entry);
    res.writeHead(202);
    return res.end();
  } else if (msg.method === "tools/list") {
    result = { tools: (w.tools ?? ALL_TOOLS).map((name) => ({ name, inputSchema: { type: "object" } })) };
  } else if (msg.method === "tools/call") {
    let changed;
    [result, changed] = callTool(w, msg.params.name, msg.params.arguments ?? {});
    if (changed) saveWorld(w);
  } else {
    return json(res, 200, { jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not found" } });
  }
  log(w, entry);
  const reply = { jsonrpc: "2.0", id: msg.id, result };
  const headers = { "mcp-session-id": "sess-fake" };
  if (w.sse) {
    res.writeHead(200, { "content-type": "text/event-stream", ...headers });
    return res.end(`event: message\ndata: ${JSON.stringify(reply)}\n\n`);
  }
  return json(res, 200, reply, headers);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  try {
    if (req.method === "POST" && url.pathname === "/mcp") return await mcp(req, res);
    if (req.method === "POST" && url.pathname === "/oauth/mcp/register") {
      const b = JSON.parse(await body(req));
      const id = `client-${randomBytes(4).toString("hex")}`;
      clients.set(id, b);
      log(loadWorld(), { path: url.pathname, client_name: b.client_name });
      return json(res, 201, { client_id: id });
    }
    if (req.method === "POST" && url.pathname === "/oauth/mcp/decision") {
      const b = JSON.parse(await body(req));
      log(loadWorld(), { path: url.pathname, tag: b.decision?._tag, access: b.decision?.access });
      if (b.decision?.code !== "PAIR-OK") return json(res, 400, { error: "invalid_pairing" });
      const code = randomBytes(8).toString("hex");
      codes.set(code, { challenge: b.authorization.code_challenge, access: b.decision.access });
      const to = new URL(b.authorization.redirect_uri);
      to.searchParams.set("code", code);
      to.searchParams.set("state", b.authorization.state);
      return json(res, 200, { redirectTo: to.href });
    }
    if (req.method === "POST" && url.pathname === "/oauth/mcp/token") {
      const b = new URLSearchParams(await body(req));
      const w = loadWorld();
      const entry = codes.get(b.get("code"));
      const challenge = createHash("sha256").update(b.get("code_verifier") ?? "").digest("base64url");
      log(w, { path: url.pathname, grant_type: b.get("grant_type"), pkce: Boolean(entry && entry.challenge === challenge) });
      if (!entry || entry.challenge !== challenge) return json(res, 400, { error: "invalid_grant" });
      const token = `tok-${randomBytes(12).toString("hex")}`;
      w.tokens = [...(w.tokens ?? []), token];
      saveWorld(w);
      return json(res, 200, { access_token: token, token_type: "Bearer", expires_in: w.expiresIn ?? 2592000, scope: "orchestration:read orchestration:operate" });
    }
    json(res, 404, { error: "not_found" });
  } catch (e) {
    json(res, 500, { error: String(e) });
  }
});

server.listen(0, "127.0.0.1", () => {
  writeFileSync(args["port-file"], String(server.address().port));
});

if (args["parent-pid"]) {
  setInterval(() => {
    try {
      process.kill(Number(args["parent-pid"]), 0);
    } catch {
      process.exit(0);
    }
  }, 500).unref();
}
