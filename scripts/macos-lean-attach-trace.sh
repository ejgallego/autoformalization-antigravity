#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <out-dir> <command> [args...]" >&2
  exit 2
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "macos-lean-attach-trace.sh only supports macOS" >&2
  exit 2
fi

out_dir="$1"
shift
mkdir -p "$out_dir"

summary="$out_dir/attach-summary.md"
: > "$summary"

target_pattern="${MACOS_ATTACH_TARGET_PATTERN:-lean( .*)?--run CI/MathlibImportNoop\.lean}"
attach_seconds="${MACOS_ATTACH_SECONDS:-45}"

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

wait_for_target_pid() {
  local deadline="$1"
  local pid=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      case "$(ps -p "$pid" -o comm= 2>/dev/null || true)" in
        lean|*/lean)
          printf '%s\n' "$pid"
          return 0
          ;;
      esac
    done < <(pgrep -f "$target_pattern" || true)
    sleep 0.05
  done
  return 1
}

capture_static_context() {
  local pid="$1"
  local prefix="$2"

  {
    echo "--- $(date -u) pid=$pid ---"
    ps -p "$pid" -o pid,ppid,%cpu,%mem,etime,command || true
    echo
    echo "--- lsof summary ---"
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
    echo
    echo "--- vmmap summary ---"
    vmmap -summary "$pid" 2>/dev/null | head -120 || true
    echo
    echo "--- sample ---"
    sample "$pid" 5 1 2>&1 | grep -E 'Call graph|Sort by top|Lean_importModules|Lean_finalizeImport|mmap|open|pread|read|fsync|msync|PAGE' || true
  } > "$out_dir/${prefix}-context.log" 2>&1
}

summarize_dtrace_attach() {
  local raw="$1"
  local out="$2"

  {
    echo "### DTrace mmap attach counts"
    echo
    awk '
      {
        if ($0 ~ /probe=mmap /) mmap++
        if ($0 ~ /probe=mmap_extended/) mmap_extended++
        if ($0 ~ /msync|fsync/) sync++
        if (match($0, /arg2=-?[0-9]+/)) {
          prot = substr($0, RSTART + 5, RLENGTH - 5)
          prots[prot]++
        }
        if (match($0, /arg3=-?[0-9]+/)) {
          flag = substr($0, RSTART + 5, RLENGTH - 5)
          flags[flag]++
        }
      }
      END {
        print "mmap", mmap + 0
        print "mmap_extended", mmap_extended + 0
        print "sync_lines", sync + 0
        print ""
        print "arg2_prot_counts"
        for (prot in prots) print prots[prot], prot
        print ""
        print "arg3_flag_counts"
        for (flag in flags) print flags[flag], flag
      }
    ' "$raw"

    echo
    echo "### first mmap/sync lines"
    echo
    awk '/probe=mmap|probe=mmap_extended|probe=msync|probe=fsync/ { print; if (++n == 200) exit }' "$raw" || true

    echo
    echo "### first error/warning lines"
    echo
    awk '/dtrace|DTrace|failed|denied|not permitted|invalid|error|drop/ { print; if (++n == 80) exit }' "$raw" || true
  } > "$out"
}

raw_dtrace="$out_dir/macos-dtrace-mmap.raw"
dtrace_summary="$out_dir/macos-dtrace-mmap-summary.txt"
time_log="$out_dir/command-time.txt"
pid_log="$out_dir/target-pid.txt"
vm_before="$out_dir/vm-stat-before.txt"
vm_after="$out_dir/vm-stat-after.txt"

append_summary "## macOS Lean PID Attach Trace"
append_summary
append_summary '```text'
print_command "$@" >> "$summary"
append_summary '```'
append_summary

vm_stat > "$vm_before" 2>&1 || true

set +e
/usr/bin/time -l "$@" > "$out_dir/command.stdout" 2> "$time_log" &
cmd_pid="$!"
set -e

deadline="$(( $(date +%s) + 90 ))"
target_pid=""
if target_pid="$(wait_for_target_pid "$deadline")"; then
  printf '%s\n' "$target_pid" > "$pid_log"
  capture_static_context "$target_pid" "before-attach"

  {
    echo "attaching raw DTrace mmap probe to pid $target_pid for ${attach_seconds}s at $(date -u)"
    sudo -n dtrace -q -p "$target_pid" -n '
      syscall:::entry
      /probefunc == "mmap" || probefunc == "mmap_extended" || probefunc == "msync" || probefunc == "fsync"/
      {
        printf("probe=%s arg0=%p arg1=%d arg2=%d arg3=%d arg4=%d arg5=%d\n",
          probefunc, arg0, arg1, arg2, arg3, arg4, arg5);
      }
    ' 2>&1 &
    dtrace_pid="$!"
    sleep "$attach_seconds"
    kill -INT "$dtrace_pid" 2>/dev/null || true
    wait "$dtrace_pid" 2>/dev/null || true
    echo "detached raw DTrace mmap probe at $(date -u)"
  } > "$raw_dtrace" 2>&1

  if kill -0 "$target_pid" 2>/dev/null; then
    capture_static_context "$target_pid" "after-attach"
  fi
else
  echo "target process not found for pattern: $target_pattern" > "$pid_log"
  {
    echo "target process not found"
    ps -axo pid,ppid,etime,command | grep -E 'lean|lake' | grep -v grep || true
  } > "$raw_dtrace"
fi

set +e
wait "$cmd_pid"
status="$?"
set -e

vm_stat > "$vm_after" 2>&1 || true
summarize_dtrace_attach "$raw_dtrace" "$dtrace_summary"

append_summary "Exit status: $status"
append_summary
append_summary "### target pid"
append_summary '```text'
cat "$pid_log" >> "$summary" || true
append_summary '```'
append_summary
append_summary "### time"
append_summary '```text'
cat "$time_log" >> "$summary" || true
append_summary '```'
append_summary
append_summary "### DTrace mmap attach summary"
append_summary '```text'
cat "$dtrace_summary" >> "$summary"
append_summary '```'
append_summary
append_summary "### vmmap/sample excerpts"
append_summary '```text'
grep -E 'open_files=|Lean_importModules|Lean_finalizeImport|TOTAL|MALLOC|mapped file|__TEXT|__DATA|^---' "$out_dir"/*-context.log | head -260 >> "$summary" || true
append_summary '```'

exit "$status"
