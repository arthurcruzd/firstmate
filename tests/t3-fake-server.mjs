#!/usr/bin/env node
// tests/t3-fake-server.mjs - a fake T3 Code server for the t3 backend suites
// (tests/fm-t3-mcp.test.sh, tests/fm-backend-t3.test.sh).
//
// It serves T3's headless OAuth sign-in (/oauth/mcp/register, /decision,
// /token) and the Orchestrator V2 `/mcp` streamable-HTTP endpoint with the
// tool subset bin/fm-t3-mcp.mjs drives, keeping threads in memory. Shapes
// follow T3 0.0.46 nightly as recorded in docs/verification/runtime-backends.md.
//
// Usage: t3-fake-server.mjs --config <json> --log <jsonl> --port-file <file> [--parent-pid <pid>]
// The config file is re-read on every request, so a case can change behavior
// mid-run. Keys (all optional):
//   environmentId, serverVersion, tools (array of names; default all),
//   revoked (bool: every /mcp call answers 401), sse (bool: SSE replies),
//   expiresIn (seconds), bindWorktree (override the bound worktreePath),
//   archiveKeepsRun (bool: archive leaves activeRunId set),
//   waitTimesOut (bool), failTools ({name: {code, message}}).
// Every request is appended to the log as one JSON line.

import { createHash, randomBytes } from "node:crypto";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].slice(2)] = process.argv[i + 1];

const ALL_TOOLS = [
  "t3_thread_launch", "t3_thread_send", "t3_thread_read", "t3_thread_wait", "t3_thread_interrupt",
  "t3_thread_organize", "t3_project_list", "t3_project_create", "t3_environment_read", "orchestrator_capabilities",
];
const CAPS = {
  runtimeMode: "full-access",
  providers: [
    {
      providerInstanceId: "codex", driverKind: "codex", constraints: [],
      models: [{ id: "gpt-5.6-luna", options: [{ id: "reasoningEffort", type: "select", options: [{ id: "low" }, { id: "medium" }, { id: "high" }] }] }],
    },
    {
      providerInstanceId: "claudeAgent", driverKind: "claudeAgent", constraints: [],
      models: [
        { id: "claude-sonnet-5-5", options: [{ id: "effort", type: "select", options: [{ id: "low" }, { id: "medium" }, { id: "high" }] }] },
        { id: "claude-haiku-4-5", options: [{ id: "thinking", type: "boolean" }] },
      ],
    },
    { providerInstanceId: "grok", driverKind: "grok", constraints: ["Grok is disabled in T3 Code settings."], models: [] },
  ],
};

const cfg = () => {
  try {
    return JSON.parse(readFileSync(args.config, "utf8"));
  } catch {
    return {};
  }
};
const log = (entry) => appendFileSync(args.log, `${JSON.stringify(entry)}\n`);

const clients = new Map();
const codes = new Map();
const tokens = new Set();
const projects = [];
const threads = new Map();
const requestIds = new Map();
let seq = 0;

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

function threadView(t) {
  const { messages, ...rest } = t;
  return { ...rest, itemCount: messages.length };
}

function callTool(name, a) {
  const c = cfg();
  const fail = (c.failTools ?? {})[name];
  if (fail) return err(fail.code, fail.message);
  switch (name) {
    case "t3_environment_read":
      return ok({ environmentId: c.environmentId ?? "env-fake-1", serverVersion: c.serverVersion ?? "0.0.46-nightly.fake" });
    case "orchestrator_capabilities":
      return ok(CAPS);
    case "t3_project_list":
      return ok({ projects });
    case "t3_project_create": {
      if (projects.some((p) => p.workspaceRoot === a.workspaceRoot)) return err("invalid_request", "workspace already registered");
      const p = { projectId: `mcp:proj-${++seq}`, title: a.title, workspaceRoot: a.workspaceRoot };
      projects.push(p);
      return ok({ projectId: p.projectId });
    }
    case "t3_thread_launch": {
      const ws = a.workspaceStrategy ?? {};
      const t = {
        threadId: `mcp:thread-${++seq}`, projectId: a.projectId, title: a.title, status: "idle", activeRunId: null,
        providerInstanceId: a.modelSelection?.instanceId, model: a.modelSelection?.model, modelOptions: a.modelSelection?.options ?? [],
        runtimeMode: a.runtimeMode, worktreePath: c.bindWorktree ?? ws.worktreePath ?? null, archived: false,
        pendingRequestCount: 0, runCount: 0, messages: [],
      };
      threads.set(t.threadId, t);
      if (a.message) {
        t.messages.push(a.message);
        t.runCount++;
        t.status = "running";
        t.activeRunId = `run:${t.threadId}:${t.runCount}`;
      }
      return ok({ threadId: t.threadId, projectId: t.projectId, runId: t.activeRunId, status: a.message ? "preparing" : null });
    }
    case "t3_thread_send": {
      const t = threads.get(a.threadId);
      if (!t) return err("thread_not_found", `Thread ${a.threadId} is no longer available.`);
      if (t.archived) return err("thread_not_sendable", `Thread ${a.threadId} is archived and cannot receive messages.`);
      const key = `${a.threadId}|${a.clientRequestId}`;
      if (a.clientRequestId && requestIds.has(key)) return ok(requestIds.get(key));
      t.messages.push(a.message);
      const delivery = t.activeRunId ? "steered" : "started";
      if (!t.activeRunId) {
        t.runCount++;
        t.activeRunId = `run:${t.threadId}:${t.runCount}`;
      }
      t.status = "running";
      const out = { delivery, status: t.status, runId: t.activeRunId };
      if (a.clientRequestId) requestIds.set(key, out);
      return ok(out);
    }
    case "t3_thread_read": {
      const t = threads.get(a.threadId);
      if (!t) return err("thread_not_found", `Thread ${a.threadId} is no longer available.`);
      // Like T3, the activity timeline pages oldest first from afterPosition.
      const items = t.messages.map((m, position) => ({ position, type: "user_message", status: "completed", text: m }));
      const page = items.filter((it) => a.afterPosition == null || it.position > a.afterPosition).slice(0, a.limit ?? 100);
      const last = page.at(-1)?.position ?? null;
      return ok({ thread: threadView(t), recentRuns: [], items: page, nextPosition: last, hasMore: last !== null && last < items.length - 1 });
    }
    case "t3_thread_wait": {
      const t = threads.get(a.threadId);
      if (!t) return err("thread_not_found", `Thread ${a.threadId} is no longer available.`);
      if (c.waitTimesOut) return ok({ threadId: t.threadId, runId: t.activeRunId, status: "running", timedOut: true });
      return ok({ threadId: t.threadId, runId: null, status: t.status, timedOut: false });
    }
    case "t3_thread_interrupt": {
      const t = threads.get(a.threadId);
      if (!t) return err("thread_not_found", `Thread ${a.threadId} is no longer available.`);
      if (!t.activeRunId) return ok({ threadId: t.threadId, runId: null, status: "no_active_run" });
      if (!c.waitTimesOut) {
        t.activeRunId = null;
        t.status = "interrupted";
      }
      return ok({ threadId: t.threadId, status: "interrupt_requested" });
    }
    case "t3_thread_organize": {
      const t = threads.get(a.threadId);
      if (!t) return err("thread_not_found", `Thread ${a.threadId} is no longer available.`);
      if (a.action === "archive") {
        t.archived = true;
        if (!c.archiveKeepsRun && t.activeRunId) {
          t.activeRunId = null;
          t.status = "interrupted";
        }
      }
      return ok({ threadId: t.threadId, action: a.action });
    }
    default:
      return err("unknown_tool", `no tool ${name}`);
  }
}

async function mcp(req, res) {
  const c = cfg();
  const auth = req.headers.authorization ?? "";
  if (c.revoked || !tokens.has(auth.replace(/^Bearer /, ""))) {
    log({ path: "/mcp", status: 401 });
    return json(res, 401, { error: "invalid_token" });
  }
  const msg = JSON.parse(await body(req));
  let result;
  if (msg.method === "initialize") {
    result = { protocolVersion: msg.params.protocolVersion, serverInfo: { name: "t3", version: c.serverVersion ?? "0.0.46-nightly.fake" }, capabilities: { tools: {} } };
  } else if (msg.method === "notifications/initialized") {
    log({ path: "/mcp", method: msg.method, protocol: req.headers["mcp-protocol-version"] });
    res.writeHead(202);
    return res.end();
  } else if (msg.method === "tools/list") {
    const names = c.tools ?? ALL_TOOLS;
    result = { tools: names.map((name) => ({ name, inputSchema: { type: "object" } })) };
  } else if (msg.method === "tools/call") {
    result = callTool(msg.params.name, msg.params.arguments ?? {});
  } else {
    return json(res, 200, { jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not found" } });
  }
  log({ path: "/mcp", method: msg.method, tool: msg.params?.name, arguments: msg.params?.arguments, protocol: req.headers["mcp-protocol-version"] });
  const reply = { jsonrpc: "2.0", id: msg.id, result };
  const headers = { "mcp-session-id": "sess-fake" };
  if (c.sse) {
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
      const id = `client-${++seq}`;
      clients.set(id, b);
      log({ path: url.pathname, client_name: b.client_name });
      return json(res, 201, { client_id: id });
    }
    if (req.method === "POST" && url.pathname === "/oauth/mcp/decision") {
      const b = JSON.parse(await body(req));
      log({ path: url.pathname, tag: b.decision?._tag, access: b.decision?.access });
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
      const entry = codes.get(b.get("code"));
      const challenge = createHash("sha256").update(b.get("code_verifier") ?? "").digest("base64url");
      log({ path: url.pathname, grant_type: b.get("grant_type"), pkce: Boolean(entry && entry.challenge === challenge) });
      if (!entry || entry.challenge !== challenge) return json(res, 400, { error: "invalid_grant" });
      const token = `tok-${randomBytes(12).toString("hex")}`;
      tokens.add(token);
      return json(res, 200, { access_token: token, token_type: "Bearer", expires_in: cfg().expiresIn ?? 2592000, scope: "orchestration:read orchestration:operate" });
    }
    if (req.method === "POST" && url.pathname === "/test/token") {
      // Test hook: register a bearer directly, for cases that skip sign-in.
      const t = (await body(req)).trim();
      tokens.add(t);
      return json(res, 200, { ok: true });
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
