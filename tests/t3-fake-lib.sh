#!/usr/bin/env bash
# tests/t3-fake-lib.sh - shared fixture helpers for the t3 backend suites:
# start and stop tests/t3-fake-server.mjs, edit its live config, and mint
# credentials it accepts. Sourced after tests/lib.sh.

T3_FAKE_SERVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/t3-fake-server.mjs"
T3_FAKE_PID=

# t3_fake_start <dir> [VAR=value...]: start a server under <dir>, with the
# extra environment given. Sets T3_FAKE_URL, T3_FAKE_CFG, T3_FAKE_LOG.
t3_fake_start() {
  local dir=$1 i
  shift
  mkdir -p "$dir"
  T3_FAKE_CFG="$dir/config.json"
  T3_FAKE_LOG="$dir/requests.jsonl"
  [ -f "$T3_FAKE_CFG" ] || printf '{}\n' > "$T3_FAKE_CFG"
  : > "$T3_FAKE_LOG"
  rm -f "$dir/port"
  env -u T3CODE_TELEMETRY_ENABLED "$@" node "$T3_FAKE_SERVER" --config "$T3_FAKE_CFG" --log "$T3_FAKE_LOG" \
    --port-file "$dir/port" --parent-pid "$$" >"$dir/server.out" 2>&1 &
  T3_FAKE_PID=$!
  for i in $(seq 1 100); do
    [ -s "$dir/port" ] && break
    sleep 0.05
  done
  [ -s "$dir/port" ] || fail "fake T3 server did not start: $(cat "$dir/server.out" 2>/dev/null)"
  T3_FAKE_URL="http://127.0.0.1:$(cat "$dir/port")"
}

t3_fake_stop() {
  [ -n "$T3_FAKE_PID" ] || return 0
  kill "$T3_FAKE_PID" 2>/dev/null || true
  wait "$T3_FAKE_PID" 2>/dev/null || true
  T3_FAKE_PID=
}

# t3_fake_config <json>: replace the server's live config.
t3_fake_config() {
  printf '%s\n' "$1" > "$T3_FAKE_CFG"
}

# t3_fake_t3_cli <dir>: a fake `t3` CLI whose pairing create prints the code
# the fake server accepts and logs its arguments to <dir>/t3-cli.log.
t3_fake_t3_cli() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/t3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/t3-cli.log'
printf '{"credential":"PAIR-OK","expiresAt":"later"}\n'
SH
  chmod +x "$dir/t3"
  printf '%s\n' "$dir/t3"
}

# t3_fake_credential <file> [env-id] [expires-at-ms] [mode]: a credential the
# running server accepts, written without the sign-in flow.
t3_fake_credential() {
  local file=$1 env=${2:-env-fake-1} expires=${3:-} mode=${4:-600} token
  [ -n "$expires" ] || expires=$(( ($(date +%s) + 30 * 86400) * 1000 ))
  token="tok-test-$RANDOM$RANDOM"
  curl -s --max-time 5 -X POST --data "$token" "$T3_FAKE_URL/test/token" >/dev/null \
    || fail "could not register a fake T3 bearer"
  mkdir -p "$(dirname "$file")"
  printf '{"version":1,"origin":"%s","access_token":"%s","issued_at":0,"expires_at":%s,"access":"full-access","environment_id":"%s","server_version":"0.0.46-nightly.fake"}\n' \
    "$T3_FAKE_URL" "$token" "$expires" "$env" > "$file"
  chmod "$mode" "$file"
}

# t3_fake_calls <tool>: the logged arguments of every call to <tool>, one JSON
# object per line.
t3_fake_calls() {
  node -e '
const tool = process.argv[1];
for (const line of require("fs").readFileSync(process.argv[2], "utf8").split("\n")) {
  if (!line) continue;
  const e = JSON.parse(line);
  if (e.tool === tool) console.log(JSON.stringify(e.arguments ?? {}));
}
' "$1" "$T3_FAKE_LOG"
}
