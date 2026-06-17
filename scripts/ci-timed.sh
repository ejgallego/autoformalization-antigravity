#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <label> <command> [args...]" >&2
  exit 2
fi

label="$1"
shift

echo "==> $label"
printf 'Command:'
for arg in "$@"; do
  printf ' %q' "$arg"
done
printf '\n'

sample_processes() {
  while sleep 60; do
    echo "::group::process snapshot for $label"
    date -u
    ps -axo pid,ppid,%cpu,%mem,etime,command | grep -E '([l]ake|[l]ean|[c]lang|[l]d)' || true
    echo "::endgroup::"
  done
}

sample_processes &
sampler_pid="$!"

cleanup() {
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
}
trap cleanup EXIT

start="$(date +%s)"
set +e
/usr/bin/time -p "$@"
status="$?"
set -e
end="$(date +%s)"
elapsed="$((end - start))"

cleanup
trap - EXIT

echo "$label elapsed seconds: $elapsed"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "elapsed_seconds=$elapsed" >> "$GITHUB_OUTPUT"
fi

if [ "$status" -eq 0 ] && [ -n "${CI_TIMED_THRESHOLD_SECONDS:-}" ]; then
  if ! [[ "$CI_TIMED_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Invalid CI_TIMED_THRESHOLD_SECONDS: $CI_TIMED_THRESHOLD_SECONDS" >&2
    exit 2
  fi

  if [ "$elapsed" -gt "$CI_TIMED_THRESHOLD_SECONDS" ]; then
    echo "::error::$label took ${elapsed}s, above ${CI_TIMED_THRESHOLD_SECONDS}s."
    exit 1
  fi
fi

exit "$status"
