#!/usr/bin/env bash
# tests/fm-remote-secondmate-move.test.sh - the remote route's registry
# endpoint (bin/fm-secondmate-registry-lib.sh) and
# bin/fm-remote-secondmate-move.sh, which moves a remote second mate between
# its host's Herdr session and that host's T3 Code server.
#
# The remote transport is faked at the SSH boundary, as the other
# remote-secondmate suites fake it. The fake host answers the doctor, the
# route read, and the release verb, and refuses everything else, so the
# ordinary launch the move hands off to stops at its own readiness gate; that
# gate's doctor call is recorded to prove it asked for the target endpoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP=$(fm_test_tmproot fm-remote-secondmate-move)
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
CALLS="$TMP/ssh-calls"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"

HERDR_LINE='- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS work; projects: alpha; added 2026-08-01)'
T3_LINE='- ios - iOS delivery (host: remote-mac; root: /srv/fm; endpoint: t3code; home: /srv/fm-home; scope: iOS work; projects: alpha; added 2026-08-01)'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = remote-mac ] || exit 91
argv=$(perl -MMIME::Base64=decode_base64 -e 'my @a=split(/\0/, decode_base64($ARGV[0])); print join(" ", @a);' "$6")
printf '%s\n' "$argv" >> "$FM_FAKE_CALLS"
case "$argv" in
  'fm-remote-doctor.sh'*)
    [ "${FM_FAKE_DOCTOR:-ok}" = ok ] && { echo 'ok: remote second-mate readiness confirmed on this host'; exit 0; }
    echo 'check t3-credential=human: no T3 credential'; exit 1 ;;
  'fm-remote-secondmate-control.sh route ios')
    printf 'schema=fm-remote-secondmate-control.v1\nbackend=%s\ntarget=x\nharness=claude\n' "$FM_FAKE_RECORDED"; exit 0 ;;
  'fm-remote-secondmate-control.sh release ios')
    [ "${FM_FAKE_RELEASE:-ok}" = ok ] && { echo 'released: ios backend=herdr'; exit 0; }
    echo 'error: remote secondmate ios is busy on herdr; release it once its turn has ended' >&2; exit 1 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/fake-ssh"

move() {  # <target> -> MOVE_OUT, MOVE_RC
  : > "$CALLS"
  set +e
  MOVE_OUT=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_CALLS="$CALLS" \
    FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-remote-secondmate-move.sh" ios "$1" 2>&1)
  MOVE_RC=$?
  set -e
}

registry_endpoint() {
  bash -c '. "$1/bin/fm-secondmate-registry-lib.sh"; secondmate_registry_field "$2" ios endpoint' _ "$ROOT" "$HOME_DIR/data/secondmates.md"
}

set -e

# --- the registry endpoint field --------------------------------------------

printf '%s\n' "$HERDR_LINE" > "$HOME_DIR/data/secondmates.md"
[ "$(registry_endpoint)" = herdr ] || fail "a route without an endpoint field must read as herdr"
printf '%s\n' "$T3_LINE" > "$HOME_DIR/data/secondmates.md"
[ "$(registry_endpoint)" = t3code ] || fail "endpoint: t3code must read back as t3code"
bash -c '. "$1/bin/fm-secondmate-registry-lib.sh"; secondmate_registry_field "$2" ios home' _ "$ROOT" "$HOME_DIR/data/secondmates.md" \
  | grep -qx /srv/fm-home || fail "the endpoint field must not shift the home field"
printf '%s\n' "${HERDR_LINE/root: \/srv\/fm;/root: /srv/fm; endpoint: tmux;}" > "$HOME_DIR/data/secondmates.md"
if bash -c '. "$1/bin/fm-secondmate-registry-lib.sh"; secondmate_registry_parse_line "$(cat "$2")"' _ "$ROOT" "$HOME_DIR/data/secondmates.md"; then
  fail "an unknown endpoint value must make the record malformed"
fi
pass "the registry endpoint field defaults to herdr, reads t3code, and refuses any other value"

# --- a host that is not ready for the target changes nothing -----------------

printf '%s\n' "$HERDR_LINE" > "$HOME_DIR/data/secondmates.md"
cp "$HOME_DIR/data/secondmates.md" "$TMP/registry.before"
FM_FAKE_DOCTOR=gap FM_FAKE_RECORDED=herdr move t3code
[ "$MOVE_RC" -ne 0 ] || fail "a move to an unready host must refuse"
assert_contains "$MOVE_OUT" "not ready for the t3code endpoint" "the refusal must name the target endpoint"
cmp -s "$TMP/registry.before" "$HOME_DIR/data/secondmates.md" || fail "a refused readiness check changed the registry"
assert_contains "$(cat "$CALLS")" "fm-remote-doctor.sh --endpoint t3code" "readiness must be checked for the target endpoint"
assert_not_contains "$(cat "$CALLS")" release "a refused readiness check must not release the old endpoint"
pass "a host not ready for the target endpoint refuses the move before anything changes"

# --- a busy mate keeps its endpoint and the registry is restored -------------

FM_FAKE_RELEASE=busy FM_FAKE_RECORDED=herdr move t3code
[ "$MOVE_RC" -ne 0 ] || fail "a move of a busy mate must refuse"
assert_contains "$MOVE_OUT" "keeps running there" "the refusal must say the mate keeps its endpoint"
cmp -s "$TMP/registry.before" "$HOME_DIR/data/secondmates.md" || fail "a refused release left the registry rewritten"
pass "a mate the host will not release keeps its endpoint and its registry record"

# --- a released mate's route names the target, and launch gates on it --------

FM_FAKE_RECORDED=herdr move t3code
[ "$(registry_endpoint)" = t3code ] || fail "a released move must rewrite the endpoint to t3code"
[ "$(cat "$HOME_DIR/data/secondmates.md")" = "$T3_LINE" ] || fail "the move must change only the endpoint field, got: $(cat "$HOME_DIR/data/secondmates.md")"
assert_contains "$(cat "$CALLS")" "fm-remote-secondmate-control.sh release ios" "the old endpoint must be released"
[ "$(grep -c 'fm-remote-doctor.sh --endpoint t3code' "$CALLS")" -ge 2 ] \
  || fail "the launch the move hands off to must gate on the t3code readiness set: $(cat "$CALLS")"
[ "$MOVE_RC" -ne 0 ] || fail "the fake host refuses the launch, so the move must report it"
assert_contains "$MOVE_OUT" "move it back with" "a failed launch must name the way back"
[ ! -e "$HOME_DIR/state/.secondmate-liveness-ios.lock" ] || fail "the move must release the mate's liveness lock"

FM_FAKE_RECORDED=t3code move herdr
[ "$(cat "$HOME_DIR/data/secondmates.md")" = "$HERDR_LINE" ] || fail "moving back must restore the original record, got: $(cat "$HOME_DIR/data/secondmates.md")"
pass "a move rewrites only the endpoint, releases the old endpoint, and launches through the target's readiness gate"
