// Read-only lab probe: every T3 project and its threads (archived included).
// usage: node t3probe.mjs <code-root> <token-file>
const [codeRoot, tokenFile] = process.argv.slice(2);
const m = await import(`${codeRoot}/bin/fm-t3-mcp.mjs`);
const cred = m.readCredential(tokenFile);
const s = new m.McpSession(cred.origin, cred.access_token);
await m.gate(s, cred);
const projects = [];
let cursor;
for (;;) {
  const l = await s.call("t3_project_list", { limit: 100, ...(cursor !== undefined ? { cursor } : {}) });
  projects.push(...(l?.projects ?? []));
  if (l?.nextCursor == null) break;
  cursor = l.nextCursor;
}
const out = [];
for (const p of projects) {
  let threads = [];
  let c;
  for (;;) {
    const l = await s.call("t3_thread_list", { projectId: p.id ?? p.projectId, includeArchived: true, includeSubagents: false, limit: 100, ...(c !== undefined ? { cursor: c } : {}) });
    threads.push(...(l?.threads ?? []));
    if (l?.nextCursor == null) break;
    c = l.nextCursor;
  }
  out.push({ projectId: p.id ?? p.projectId, deleted: !!p.deletedAt, title: p.title, workspaceRoot: p.workspaceRoot, threads: threads.map((t) => ({ threadId: t.threadId ?? t.id, status: t.status, archived: t.archivedAt != null || t.archived === true })) });
}
console.log(JSON.stringify({ projectCount: out.length, threadCount: out.reduce((n, p) => n + p.threads.length, 0), projects: out }, null, 1));
await s.close();
