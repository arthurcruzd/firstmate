// Lab-only HTTP proxy in front of the real lab T3 server.
// Every request is forwarded to T3 unchanged. For a tools/call of
// t3_thread_send, the next line of <plan-file> decides the reply: "pass"
// returns T3's real reply; "drop" waits for T3's full reply (so T3 has
// committed the send) and then answers the client 502, a lost reply.
// Each t3_thread_send is logged to <log-file> with its clientRequestId and
// the verdict applied.
// Usage: node lossy-proxy.mjs <listen-port> <upstream-origin> <plan-file> <log-file>
import http from "node:http";
import fs from "node:fs";

const [port, upstream, planFile, logFile] = process.argv.slice(2);

function nextVerdict() {
  let lines = [];
  try { lines = fs.readFileSync(planFile, "utf8").split("\n").filter(Boolean); } catch {}
  const v = lines.shift() ?? "pass";
  fs.writeFileSync(planFile, lines.length ? lines.join("\n") + "\n" : "");
  return v;
}

http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    const body = Buffer.concat(chunks);
    let rpc = null;
    try { rpc = JSON.parse(body.toString("utf8")); } catch {}
    const isSend = rpc?.method === "tools/call" && rpc?.params?.name === "t3_thread_send";
    const verdict = isSend ? nextVerdict() : "pass";
    const headers = { ...req.headers };
    delete headers.host;
    delete headers["content-length"];
    try {
      const up = await fetch(upstream + req.url, { method: req.method, headers, body: ["GET", "HEAD"].includes(req.method) ? undefined : body });
      const buf = Buffer.from(await up.arrayBuffer());
      if (isSend) {
        fs.appendFileSync(logFile, JSON.stringify({ at: new Date().toISOString(), clientRequestId: rpc.params.arguments?.clientRequestId ?? null, threadId: rpc.params.arguments?.threadId ?? null, upstreamStatus: up.status, verdict }) + "\n");
      }
      if (verdict === "drop") {
        res.writeHead(502, { "content-type": "text/plain" });
        res.end("lab proxy: reply dropped after T3 answered\n");
        return;
      }
      const out = {};
      up.headers.forEach((v, k) => { if (!["content-length", "content-encoding", "transfer-encoding", "connection"].includes(k)) out[k] = v; });
      res.writeHead(up.status, out);
      res.end(buf);
    } catch (err) {
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`lab proxy upstream error: ${err}\n`);
    }
  });
}).listen(Number(port), "127.0.0.1");
