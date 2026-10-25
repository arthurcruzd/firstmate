#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.
#
# A route whose registry record names `endpoint: t3code` is gated on the T3
# readiness set instead of the Herdr one, so the doctor runs with
# `--endpoint t3code`; a herdr route sends the doctor no endpoint argument, so
# a host code root that predates the flag still answers it.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

# fm_remote_route_endpoint <bin-dir> <secondmate-id>: herdr or t3code, read
# from the same registry fm-on.sh resolves the route from. Fails when the id has
# no remote record.
fm_remote_route_endpoint() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 root home data endpoint
  root="${FM_ROOT_OVERRIDE:-$(cd "$bin_dir/.." && pwd)}"
  home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
  data="${FM_DATA_OVERRIDE:-$home/data}"
  if ! declare -F secondmate_registry_field >/dev/null; then
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$bin_dir/fm-secondmate-registry-lib.sh"
  fi
  [ "$(secondmate_registry_field "$data/secondmates.md" "$id" remote 2>/dev/null)" = 1 ] || return 1
  endpoint=$(secondmate_registry_field "$data/secondmates.md" "$id" endpoint) || return 1
  printf '%s\n' "${endpoint:-herdr}"
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 out rc endpoint
  local -a endpoint_args=()

  endpoint=$(fm_remote_route_endpoint "$bin_dir" "$id" 2>/dev/null || true)
  [ "$endpoint" != t3code ] || endpoint_args=(--endpoint t3code)

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh ${endpoint_args[@]+"${endpoint_args[@]}"} < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh --fix ${endpoint_args[@]+"${endpoint_args[@]}"} < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh ${endpoint_args[@]+"${endpoint_args[@]}"} < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
