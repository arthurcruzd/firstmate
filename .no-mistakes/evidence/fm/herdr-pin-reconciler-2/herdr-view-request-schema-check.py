#!/usr/bin/env python3
"""Capture the exact request bin/backends/herdr-agent-view.py sends, then check
it against the installed Herdr binary's own bundled API schema
(`herdr api schema --json`). A capture socket stands in for the server, so this
is a protocol-shape check, not a live Herdr run."""
import json, os, socket, subprocess, sys, tempfile, threading

helper, schema_path = sys.argv[1], sys.argv[2]
root = json.load(open(schema_path))

def resolve(ref):
    node = root
    for part in ref.lstrip("#/").split("/"):
        node = node[part]
    return node

def check(value, schema, path="$"):
    if "$ref" in schema:
        return check(value, resolve(schema["$ref"]), path)
    errs = []
    for key in ("oneOf", "anyOf"):
        if key in schema:
            ok = [s for s in schema[key] if not check(value, s, path)]
            if key == "oneOf" and len(ok) != 1:
                errs.append(f"{path}: oneOf matched {len(ok)}")
            if key == "anyOf" and not ok:
                errs.append(f"{path}: anyOf matched none")
    if "const" in schema and value != schema["const"]:
        errs.append(f"{path}: {value!r} != const {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errs.append(f"{path}: {value!r} not in {schema['enum']}")
    types = schema.get("type")
    if types:
        types = types if isinstance(types, list) else [types]
        pytypes = {"string": str, "object": dict, "array": list, "boolean": bool,
                   "null": type(None), "integer": int, "number": (int, float)}
        if not any(isinstance(value, pytypes[t]) for t in types):
            errs.append(f"{path}: {type(value).__name__} not {types}")
    if isinstance(value, dict):
        for req in schema.get("required", []):
            if req not in value:
                errs.append(f"{path}: missing {req}")
        props = schema.get("properties", {})
        for k, v in value.items():
            if k in props:
                errs += check(v, props[k], f"{path}.{k}")
            elif schema.get("additionalProperties") is False:
                errs.append(f"{path}: unexpected {k}")
    if isinstance(value, list) and "items" in schema:
        for i, v in enumerate(value):
            errs += check(v, schema["items"], f"{path}[{i}]")
    return errs

d = tempfile.mkdtemp(prefix="fmhv")
sock_path = os.path.join(d, "s")
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path); srv.listen(1)
captured = {}
def serve():
    conn, _ = srv.accept()
    data = b""
    while b"\n" not in data:
        data += conn.recv(4096)
    captured["req"] = json.loads(data.split(b"\n")[0])
    conn.sendall(json.dumps({"id": captured["req"]["id"], "result": {"type": "agent_view", "active": True, "source": "firstmate:pins", "label": "Pinned"}}).encode() + b"\n")
    conn.close()
t = threading.Thread(target=serve); t.start()
rc = subprocess.call([helper, sock_path]); t.join()
req = captured["req"]
print("helper exit:", rc)
print("captured request:", json.dumps(req, sort_keys=True))
envelope = [s for s in root["schemas"]["request"]["oneOf"] if s.get("properties", {}).get("method", {}).get("const") == req["method"]]
print("herdr schema protocol:", root.get("protocol"), "| request method known to this Herdr:", bool(envelope))
errs = check(req, envelope[0]) if envelope else ["method not in schema"]
print("request vs AgentViewSetParams:", "VALID" if not errs else errs)
resp = {"id": req["id"], "result": {"type": "agent_view", "active": True, "source": "firstmate:pins", "label": "Pinned"}}
rr = root["schemas"]["success_response"]["$defs"]["ResponseResult"]
branch = [s for s in rr["oneOf"] if s.get("properties", {}).get("type", {}).get("const") == "agent_view"][0]
print("agent_view response branch requires:", branch.get("required"), "| helper checks type+active against it:", not check(resp["result"], branch))
pm = root["schemas"]["request"]["$defs"]["PaneReportMetadataParams"]["properties"]["tokens"]
import re
pat = pm["propertyNames"]["pattern"]
print("token names valid for PaneReportMetadataParams.tokens:", {n: bool(re.match(pat, n)) for n in ("pin_rank", "pin_label", "pin_host")}, "| maxProperties:", pm.get("maxProperties"))
sys.exit(0 if (rc == 0 and not errs) else 1)
