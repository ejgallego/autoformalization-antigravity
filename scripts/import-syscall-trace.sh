#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <out-dir> <command> [args...]" >&2
  exit 2
fi

out_dir="$1"
shift
mkdir -p "$out_dir"

summary="$out_dir/trace-summary.md"
: > "$summary"

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

summarize_strace() {
  raw="$1"
  out="$2"

  {
    echo "### strace syscall counts"
    echo
    awk '
      {
        line = $0
        sub(/^[0-9]+[[:space:]]+/, "", line)
        sub(/^[0-9:.]+[[:space:]]+/, "", line)
        sys = line
        sub(/\(.*/, "", sys)
        if (sys ~ /^[A-Za-z0-9_]+$/) {
          count[sys]++
        }
        if ($0 ~ /\.olean/) olean++
        if ($0 ~ /\.olean\./) olean_aux++
        if ($0 ~ /\.ir/) ir++
        if ($0 ~ /fsync|fdatasync|msync/) sync++
        if ($0 ~ /MAP_SHARED/) map_shared++
        if ($0 ~ /MAP_PRIVATE/) map_private++
      }
      END {
        for (sys in count) print count[sys], sys
        print ""
        print "path_lines_with_olean", olean + 0
        print "path_lines_with_olean_aux", olean_aux + 0
        print "path_lines_with_ir", ir + 0
        print "sync_lines", sync + 0
        print "mmap_MAP_SHARED_lines", map_shared + 0
        print "mmap_MAP_PRIVATE_lines", map_private + 0
      }
    ' "$raw" | sort -nr

    echo
    echo "### strace first mmap/sync lines"
    echo
    grep -E 'mmap|msync|fsync|fdatasync' "$raw" | head -80 || true

    echo
    echo "### strace top traced Lean artifact paths"
    echo
    grep -Eo '/[^" <>]+\.(olean|ir)(\.[^" <>]+)?' "$raw" \
      | sed 's#^.*/\.lake/packages/mathlib/.lake/build/lib/lean/##' \
      | sed 's#^.*/\.lake/build/lib/lean/##' \
      | sort | uniq -c | sort -nr | head -80 || true
  } > "$out"
}

summarize_text_trace() {
  raw="$1"
  out="$2"
  title="$3"

  {
    echo "### $title counts"
    echo
    awk '
      BEGIN {
        pats[1] = "open"
        pats[2] = "stat"
        pats[3] = "getattr"
        pats[4] = "read"
        pats[5] = "pread"
        pats[6] = "mmap"
        pats[7] = "PAGE_IN"
        pats[8] = "fcntl"
        pats[9] = "fsync"
        pats[10] = "msync"
        pats[11] = "close"
      }
      {
        for (i in pats) {
          if ($0 ~ pats[i]) count[pats[i]]++
        }
        if ($0 ~ /\.olean/) olean++
        if ($0 ~ /\.olean\./) olean_aux++
        if ($0 ~ /\.ir/) ir++
      }
      END {
        for (i in pats) print count[pats[i]] + 0, pats[i]
        print ""
        print "path_lines_with_olean", olean + 0
        print "path_lines_with_olean_aux", olean_aux + 0
        print "path_lines_with_ir", ir + 0
      }
    ' "$raw" | sort -nr

    echo
    echo "### $title first mmap/sync/page-in lines"
    echo
    grep -E 'mmap|msync|fsync|PAGE_IN|F_PAGEIN|fcntl' "$raw" | head -120 || true

    echo
    echo "### $title top traced Lean artifact paths"
    echo
    grep -Eo '/[^" <>]+\.(olean|ir)(\.[^" <>]+)?' "$raw" \
      | sed 's#^.*/\.lake/packages/mathlib/.lake/build/lib/lean/##' \
      | sed 's#^.*/\.lake/build/lib/lean/##' \
      | sort | uniq -c | sort -nr | head -80 || true
  } > "$out"
}

run_linux_trace() {
  raw="$out_dir/linux-strace.raw"
  trace_summary="$out_dir/linux-strace-summary.txt"
  time_log="$out_dir/linux-strace-time.txt"

  append_summary "## Linux syscall trace"
  append_summary
  append_summary '```text'
  print_command "$@" >> "$summary"
  append_summary '```'
  append_summary

  set +e
  /usr/bin/time -p \
    strace -f -tt -T -yy -s 256 -o "$raw" \
      -e trace=file,mmap,munmap,mprotect,madvise,msync,fsync,fdatasync,fcntl,close,read,pread64 \
      "$@" > "$out_dir/command.stdout" 2> "$time_log"
  status="$?"
  set -e

  summarize_strace "$raw" "$trace_summary"

  append_summary "Exit status: $status"
  append_summary
  append_summary "### time"
  append_summary '```text'
  cat "$time_log" >> "$summary" || true
  append_summary '```'
  append_summary
  append_summary "### compact syscall summary"
  append_summary '```text'
  cat "$trace_summary" >> "$summary"
  append_summary '```'

  return "$status"
}

run_macos_fs_usage_trace() {
  raw="$out_dir/macos-fs-usage.filtered"
  err="$out_dir/macos-fs-usage.err"
  sampler="$out_dir/macos-sampler.log"
  time_log="$out_dir/macos-fs-usage-time.txt"
  trace_summary="$out_dir/macos-fs-usage-summary.txt"

  append_summary "## macOS fs_usage/vmmap trace"
  append_summary
  append_summary '```text'
  print_command "$@" >> "$summary"
  append_summary '```'
  append_summary

  (
    set +e
    sudo -n fs_usage -w -f filesys 2>"$err" \
      | awk '/lean|lake|Mathlib|\.olean|\.ir/ { print; fflush() }' > "$raw"
  ) &
  fs_pid="$!"

  (
    while true; do
      sleep 20
      pids="$(pgrep -f 'lean( .*)?CI/MathlibImportNoop\.lean' || true)"
      for pid in $pids; do
        echo "--- $(date -u) pid=$pid ---"
        ps -p "$pid" -o pid,ppid,%cpu,%mem,etime,command || true
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
        echo "--- vmmap summary ---"
        vmmap -summary "$pid" 2>/dev/null | head -80 || true
        echo "--- sample ---"
        sample "$pid" 5 1 2>&1 | grep -E 'Call graph|Sort by top|Lean_importModules|Lean_finalizeImport|mmap|open|pread|read|fsync|msync' || true
      done
      pgrep -f 'lean( .*)?CI/MathlibImportNoop\.lean' >/dev/null || true
    done
  ) > "$sampler" 2>&1 &
  sampler_pid="$!"

  set +e
  /usr/bin/time -p "$@" > "$out_dir/command.stdout" 2> "$time_log"
  status="$?"
  set -e

  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  sudo -n pkill -f 'fs_usage -w -f filesys' 2>/dev/null || true
  kill "$fs_pid" 2>/dev/null || true
  wait "$fs_pid" 2>/dev/null || true

  summarize_text_trace "$raw" "$trace_summary" "fs_usage"

  append_summary "Exit status: $status"
  append_summary
  append_summary "### time"
  append_summary '```text'
  cat "$time_log" >> "$summary" || true
  append_summary '```'
  append_summary
  append_summary "### compact fs_usage summary"
  append_summary '```text'
  cat "$trace_summary" >> "$summary"
  append_summary '```'
  append_summary
  append_summary "### vmmap/sample excerpts"
  append_summary '```text'
  grep -E 'open_files=|Lean_importModules|Lean_finalizeImport|TOTAL|MALLOC|mapped file|__TEXT|__DATA|^---' "$sampler" | head -240 >> "$summary" || true
  append_summary '```'

  return "$status"
}

run_macos_dtruss_probe() {
  raw="$out_dir/macos-dtruss.raw"
  trace_summary="$out_dir/macos-dtruss-summary.txt"

  append_summary "## macOS dtruss probe"
  append_summary

  if ! command -v dtruss >/dev/null 2>&1; then
    append_summary "dtruss is not available."
    append_summary
    return 0
  fi

  set +e
  sudo -n dtruss -f \
    -t open -t open_nocancel -t close -t read -t pread \
    -t mmap -t mmap_extended -t munmap -t mprotect -t msync -t fsync \
    -t fcntl -t stat64 -t lstat64 -t getattrlist \
    "$@" > "$raw" 2>&1
  status="$?"
  set -e

  summarize_text_trace "$raw" "$trace_summary" "dtruss"

  append_summary "Exit status: $status"
  append_summary
  append_summary "### compact dtruss summary"
  append_summary '```text'
  cat "$trace_summary" >> "$summary"
  append_summary '```'
  append_summary

  return 0
}

case "$(uname -s)" in
  Linux)
    run_linux_trace "$@"
    ;;
  Darwin)
    run_macos_dtruss_probe "$@"
    run_macos_fs_usage_trace "$@"
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 2
    ;;
esac
