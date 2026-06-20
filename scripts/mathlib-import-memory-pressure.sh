#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <out-dir>" >&2
  exit 2
fi

out_dir="$1"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

summary="$out_dir/memory-pressure-summary.md"
: > "$summary"
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

capture_snapshot() {
  local label="$1"
  local prefix="$2"
  local file="$out_dir/${prefix}.txt"

  {
    printf 'label=%s\n' "$label"
    date -u '+utc=%Y-%m-%dT%H:%M:%SZ'
    uname -a
    case "$(uname -s)" in
      Darwin)
        sw_vers
        printf '\n## sysctl hw/vm\n'
        sysctl hw.memsize hw.physicalcpu hw.logicalcpu 2>&1 || true
        sysctl vm 2>&1 | sort || true
        printf '\n## vm_stat\n'
        vm_stat 2>&1 || true
        printf '\n## memory_pressure\n'
        if command -v memory_pressure >/dev/null 2>&1; then
          memory_pressure 2>&1 || true
        else
          printf 'memory_pressure not found\n'
        fi
        printf '\n## df\n'
        df -h / "$PWD" 2>&1 || true
        ;;
      Linux)
        printf '\n## /proc/meminfo\n'
        cat /proc/meminfo 2>&1 || true
        printf '\n## /proc/vmstat\n'
        cat /proc/vmstat 2>&1 || true
        printf '\n## vmstat -s\n'
        vmstat -s 2>&1 || true
        printf '\n## df\n'
        df -h / "$PWD" 2>&1 || true
        ;;
    esac
  } > "$file"

  append_summary "### $label"
  append_summary
  append_summary '```text'
  sed -n '1,160p' "$file" >> "$summary"
  append_summary '```'
  append_summary
}

start_vm_stream() {
  local file="$1"
  case "$(uname -s)" in
    Darwin)
      vm_stat 1 > "$file" 2>&1 &
      ;;
    Linux)
      vmstat 1 > "$file" 2>&1 &
      ;;
    *)
      return 1
      ;;
  esac
  printf '%s\n' "$!"
}

monitor_processes() {
  local watched_pid="$1"
  local file="$2"
  while kill -0 "$watched_pid" 2>/dev/null; do
    {
      date -u '+utc=%Y-%m-%dT%H:%M:%SZ'
      ps -axo pid,ppid,comm,rss,vsz,pcpu,pmem,state,args \
        | awk 'NR == 1 || $0 ~ /[l]ean|[l]ake/'
      printf '\n'
    } >> "$file" 2>&1 || true
    sleep 5
  done
}

run_import_trace() {
  local prefix="mathlib-import"
  local stdout="$out_dir/${prefix}.stdout"
  local time_log="$out_dir/${prefix}.time.txt"
  local status_file="$out_dir/${prefix}.status"
  local elapsed_file="$out_dir/${prefix}.elapsed"
  local vm_stream="$out_dir/${prefix}-vm-stream.txt"
  local process_stream="$out_dir/${prefix}-process-stream.txt"
  local start end elapsed status cmd_pid vm_pid monitor_pid

  echo "==> Mathlib import with memory-pressure trace"
  print_command lake env lean --run CI/MathlibImportNoop.lean

  capture_snapshot "Before Mathlib import" "before"

  start="$(date +%s)"
  set +e
  case "$(uname -s)" in
    Darwin)
      /usr/bin/time -l bash -c 'lake env lean --run CI/MathlibImportNoop.lean' > "$stdout" 2> "$time_log" &
      ;;
    *)
      /usr/bin/time -v bash -c 'lake env lean --run CI/MathlibImportNoop.lean' > "$stdout" 2> "$time_log" &
      ;;
  esac
  cmd_pid="$!"
  vm_pid="$(start_vm_stream "$vm_stream")"
  monitor_processes "$cmd_pid" "$process_stream" &
  monitor_pid="$!"

  wait "$cmd_pid"
  status="$?"
  kill "$vm_pid" "$monitor_pid" >/dev/null 2>&1 || true
  wait "$vm_pid" "$monitor_pid" >/dev/null 2>&1 || true
  set -e
  end="$(date +%s)"
  elapsed="$((end - start))"

  printf '%s\n' "$status" > "$status_file"
  printf '%s\n' "$elapsed" > "$elapsed_file"

  capture_snapshot "After Mathlib import" "after"

  append_summary "### Mathlib import with memory-pressure trace"
  append_summary
  append_summary '```text'
  print_command lake env lean --run CI/MathlibImportNoop.lean >> "$summary"
  printf 'elapsed_seconds=%s\n' "$elapsed" >> "$summary"
  printf 'exit_status=%s\n' "$status" >> "$summary"
  cat "$time_log" >> "$summary" || true
  append_summary '```'
  append_summary

  append_summary "### During-run VM stream excerpt"
  append_summary
  append_summary '```text'
  sed -n '1,80p' "$vm_stream" >> "$summary" || true
  append_summary '```'
  append_summary

  append_summary "### During-run process stream excerpt"
  append_summary
  append_summary '```text'
  sed -n '1,120p' "$process_stream" >> "$summary" || true
  append_summary '```'
  append_summary

  if [ "$status" -ne 0 ] && [ "$overall_status" -eq 0 ]; then
    overall_status="$status"
  fi
}

append_summary "## Mathlib Import Memory Pressure"
append_summary
append_summary '```text'
printf 'uname=%s\n' "$(uname -a)" >> "$summary"
lean --version >> "$summary"
lake --version >> "$summary"
append_summary '```'
append_summary

run_import_trace

exit "$overall_status"
