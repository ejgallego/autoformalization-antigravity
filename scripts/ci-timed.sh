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

matching_pids() {
  if [ -n "${CI_TIMED_SAMPLE_PATTERN:-}" ]; then
    pgrep -f "$CI_TIMED_SAMPLE_PATTERN" || true
  elif [ "${CI_TIMED_SAMPLE:-}" = "1" ]; then
    pgrep -f 'lean --run BlueprintMain\.lean' || true
  fi
}

sample_processes() {
  while sleep 60; do
    echo "::group::process snapshot for $label"
    date -u
    ps -axo pid,ppid,%cpu,%mem,etime,command | grep -E '([l]ake|[l]ean|[c]lang|[l]d)' || true
    echo "::endgroup::"

    if [ "${CI_TIMED_LSOF:-}" = "1" ] && command -v lsof >/dev/null 2>&1; then
      for pid in $(matching_pids); do
        echo "::group::lsof summary $pid for $label"
        lsof -n -p "$pid" 2>/dev/null | awk '
          NR > 1 {
            total++
            if ($NF ~ /\.olean$/) olean++
            else if ($NF ~ /\.olean\./) olean_aux++
            else if ($NF ~ /\.ir$/) ir++
          }
          END {
            printf "open_files=%d olean=%d olean_aux=%d ir=%d\n",
              total + 0, olean + 0, olean_aux + 0, ir + 0
          }
        '
        echo "::endgroup::"
      done
    fi

    if [ "$(uname -s)" = "Darwin" ] && [ "${CI_TIMED_SAMPLE:-}" = "1" ]; then
      for pid in $(matching_pids); do
        echo "::group::sample $pid for $label"
        sample "$pid" 5 1 || true
        echo "::endgroup::"
      done
    fi
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
