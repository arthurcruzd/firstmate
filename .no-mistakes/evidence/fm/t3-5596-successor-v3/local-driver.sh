#!/bin/bash
set -eu
ROOT=$PWD
LAB=$ROOT/.test-phase-tmp/local
mkdir -p "$LAB/config" "$LAB/repo/.codex"
export FM_HOME=$LAB FM_CONFIG_OVERRIDE=$LAB/config
unset FM_BACKEND TMUX HERDR_ENV CMUX_WORKSPACE_ID
. bin/fm-backend.sh
export FM_T3CODE_ORIGIN=http://127.0.0.1:9 PASEO_AGENT_ID=adversarial
printf 'implicit selection with T3/Paseo markers: %s\n' "$(fm_backend_name)"
[ "$(fm_backend_name)" = tmux ]
printf 't3code\n' > "$LAB/config/backend"
printf 'explicit config selection: %s\n' "$(fm_backend_name)"
[ "$(fm_backend_name)" = t3code ]
export FM_BACKEND=tmux
printf 'environment override: %s\n' "$(fm_backend_name)"
[ "$(fm_backend_name)" = tmux ]
set +e
node bin/fm-t3-mcp.mjs status --token-file "$LAB/config/absent"
rc=$?
set -e
printf 'missing credential exit: %s\n' "$rc"
[ "$rc" -ne 0 ]
git init -q "$LAB/repo"
printf 'model = "project-model"\r\n' > "$LAB/repo/.codex/config.toml"
cp "$LAB/repo/.codex/config.toml" "$LAB/original"
git -C "$LAB/repo" add .codex/config.toml
git -C "$LAB/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm init
bash bin/fm-t3code-codex-env.sh check "$LAB/repo"
bash bin/fm-t3code-codex-env.sh install "$LAB/repo" FM_TASK_ID=live-check
python3 - "$LAB/repo/.codex/config.toml" <<'PY'
import sys,tomllib
with open(sys.argv[1],'rb') as f: d=tomllib.load(f)
assert d['model']=='project-model'
assert d['shell_environment_policy']['set']['FM_TASK_ID']=='live-check'
print('Installed TOML:',d)
PY
git -C "$LAB/repo" add -A
git -C "$LAB/repo" show :.codex/config.toml > "$LAB/index"
cmp "$LAB/original" "$LAB/index"
printf 'ordinary staging preserves original configuration bytes\n'
bash bin/fm-t3code-codex-env.sh cleanup "$LAB/repo"
cmp "$LAB/original" "$LAB/repo/.codex/config.toml"
printf 'cleanup restored original CRLF bytes; Git flag: '
git -C "$LAB/repo" ls-files -v .codex/config.toml
printf 'shell_environment_policy.set.PROJECT = "owned"\n' > "$LAB/repo/.codex/config.toml"
git -C "$LAB/repo" add .codex/config.toml
set +e
bash bin/fm-t3code-codex-env.sh check "$LAB/repo"
rc=$?
set -e
[ "$rc" -ne 0 ]
printf 'existing project policy refused (exit %s)\n' "$rc"
cp "$LAB/original" "$LAB/repo/.codex/config.toml"
git -C "$LAB/repo" add .codex/config.toml
bash bin/fm-t3code-codex-env.sh install "$LAB/repo" FM_TASK_ID=live-check
printf '\n# user edit\n' >> "$LAB/repo/.codex/config.toml"
cp "$LAB/repo/.codex/config.toml" "$LAB/edited"
set +e
bash bin/fm-t3code-codex-env.sh cleanup "$LAB/repo"
rc=$?
set -e
[ "$rc" -ne 0 ]
cmp "$LAB/edited" "$LAB/repo/.codex/config.toml"
[ -f "$LAB/repo/.git/fm-t3code-codex-env.json" ]
printf 'cleanup refused changed file and retained bytes and recovery journal (exit %s)\n' "$rc"
