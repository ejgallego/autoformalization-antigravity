#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <out-dir>" >&2
  exit 2
fi

out_dir="$1"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

summary="$out_dir/mmap-pattern-summary.md"
results="$out_dir/mmap-pattern-results.tsv"
: > "$summary"
printf 'probe\tfiles\tbytes_per_file\tmaps_per_file\tpasses\tpattern\telapsed_seconds\texit_status\n' > "$results"

work_dir="${MMAP_PATTERN_WORK_DIR:-${RUNNER_TEMP:-/tmp}/mmap-pattern-work}"
bin="$out_dir/mmap-pattern-probe"
files="${MMAP_PATTERN_FILES:-10000}"
bytes_per_file="${MMAP_PATTERN_BYTES_PER_FILE:-65536}"
maps_per_file="${MMAP_PATTERN_MAPS_PER_FILE:-4}"
passes="${MMAP_PATTERN_PASSES:-1}"
counts="${MMAP_PATTERN_COUNTS:-1000 2500 5000 10000}"
patterns="${MMAP_PATTERN_PATTERNS:-sequential permuted}"
overall_status=0

append_summary() {
  printf '%s\n' "$*" >> "$summary"
}

print_command() {
  printf 'Command:'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

time_command() {
  local label_text="$1"
  local prefix="$2"
  shift 2

  local stdout="$out_dir/${prefix}.stdout"
  local time_log="$out_dir/${prefix}.time.txt"
  local status_file="$out_dir/${prefix}.status"
  local elapsed_file="$out_dir/${prefix}.elapsed"
  local start end elapsed status

  echo "==> $label_text"
  print_command "$@"

  start="$(date +%s)"
  set +e
  case "$(uname -s)" in
    Darwin)
      /usr/bin/time -l "$@" > "$stdout" 2> "$time_log"
      ;;
    *)
      /usr/bin/time -v "$@" > "$stdout" 2> "$time_log"
      ;;
  esac
  status="$?"
  set -e
  end="$(date +%s)"
  elapsed="$((end - start))"

  printf '%s\n' "$status" > "$status_file"
  printf '%s\n' "$elapsed" > "$elapsed_file"

  append_summary "### $label_text"
  append_summary
  append_summary '```text'
  print_command "$@" >> "$summary"
  printf 'elapsed_seconds=%s\n' "$elapsed" >> "$summary"
  printf 'exit_status=%s\n' "$status" >> "$summary"
  cat "$stdout" >> "$summary" || true
  cat "$time_log" >> "$summary" || true
  append_summary '```'
  append_summary

  if [ "$status" -ne 0 ] && [ "$overall_status" -eq 0 ]; then
    overall_status="$status"
  fi
}

append_summary "## Synthetic mmap Pattern"
append_summary
append_summary '```text'
printf 'work_dir=%s\n' "$work_dir" >> "$summary"
printf 'files=%s\n' "$files" >> "$summary"
printf 'bytes_per_file=%s\n' "$bytes_per_file" >> "$summary"
printf 'maps_per_file=%s\n' "$maps_per_file" >> "$summary"
printf 'passes=%s\n' "$passes" >> "$summary"
printf 'counts=%s\n' "$counts" >> "$summary"
printf 'patterns=%s\n' "$patterns" >> "$summary"
printf 'uname=%s\n' "$(uname -a)" >> "$summary"
case "$(uname -s)" in
  Darwin)
    sw_vers >> "$summary"
    sysctl -n machdep.cpu.brand_string >> "$summary" || true
    ;;
  Linux)
    cat /etc/os-release >> "$summary" || true
    nproc >> "$summary" || true
    grep -m 1 'model name' /proc/cpuinfo >> "$summary" || true
    ;;
esac
append_summary '```'
append_summary

cc -O2 -Wall -Wextra -o "$bin" scripts/mmap-pattern-probe.c

rm -rf "$work_dir"
mkdir -p "$work_dir"

time_command "Prepare mmap fixture" "prepare" "$bin" prepare "$work_dir/files" "$files" "$bytes_per_file"

for count in $counts; do
  if [ "$count" -gt "$files" ]; then
    continue
  fi
  for pattern in $patterns; do
    prefix="probe-${count}-${pattern}"
    time_command "Probe $count files, $pattern touch order" "$prefix" \
      "$bin" probe "$work_dir/files" "$count" "$bytes_per_file" "$maps_per_file" "$passes" "$pattern"
    elapsed="$(cat "$out_dir/${prefix}.elapsed")"
    status="$(cat "$out_dir/${prefix}.status")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$prefix" "$count" "$bytes_per_file" "$maps_per_file" "$passes" "$pattern" "$elapsed" "$status" >> "$results"
  done
done

append_summary "### Results"
append_summary
append_summary '```text'
cat "$results" >> "$summary"
append_summary '```'
append_summary

exit "$overall_status"
