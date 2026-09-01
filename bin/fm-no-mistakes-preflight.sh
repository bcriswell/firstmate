#!/usr/bin/env bash
# fm-no-mistakes-preflight.sh - require the no-mistakes attestation-capable floor.
#
# Usage:
#   fm-no-mistakes-preflight.sh                     verify the installed client
#   fm-no-mistakes-preflight.sh --required-version  print the minimum version
#   fm-no-mistakes-preflight.sh --help              print this usage
set -u

REQUIRED_NO_MISTAKES=1.46.0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  "") ;;
  --required-version)
    printf '%s\n' "$REQUIRED_NO_MISTAKES"
    exit 0
    ;;
  --help)
    usage
    exit 0
    ;;
  *)
    printf 'fm-no-mistakes-preflight.sh: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac
[ "$#" -eq 0 ] || exit 2

if ! command -v no-mistakes >/dev/null 2>&1; then
  printf 'fm-no-mistakes-preflight.sh: no-mistakes %s or newer is required to publish structured pipeline attestation.\n' \
    "$REQUIRED_NO_MISTAKES" >&2
  exit 1
fi

output=$(no-mistakes --version 2>/dev/null) || output=
parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
IFS=' ' read -r major minor patch extra <<< "$parts"
IFS='.' read -r min_major min_minor min_patch min_extra <<< "$REQUIRED_NO_MISTAKES"
compatible=0
if [ -n "${major:-}" ] && [ -n "${minor:-}" ] && [ -n "${patch:-}" ] && [ -z "${extra:-}" ] \
  && [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "${min_extra:-}" ]; then
  if [ "$major" -gt "$min_major" ] \
    || { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } \
    || { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    compatible=1
  fi
fi

[ "$compatible" -eq 1 ] || {
  printf 'fm-no-mistakes-preflight.sh: no-mistakes %s or newer is required to publish structured pipeline attestation; found %s.\n' \
    "$REQUIRED_NO_MISTAKES" "${output:-an unreadable version}" >&2
  exit 1
}
