#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <out-dir> <macos|linux>" >&2
  exit 2
fi

out_dir="$1"
mode="$2"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

summary="$out_dir/cache-experiments-summary.md"
: > "$summary"
overall_status=0
ramdisk_device=""

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
  local label="$1"
  local prefix="$2"
  shift 2

  local stdout="$out_dir/${prefix}.stdout"
  local time_log="$out_dir/${prefix}.time.txt"
  local status_file="$out_dir/${prefix}.status"
  local start end elapsed status

  echo "==> $label"
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

  append_summary "### $label"
  append_summary
  append_summary '```text'
  print_command "$@" >> "$summary"
  printf 'elapsed_seconds=%s\n' "$elapsed" >> "$summary"
  printf 'exit_status=%s\n' "$status" >> "$summary"
  cat "$time_log" >> "$summary" || true
  append_summary '```'
  append_summary

  if [ "$status" -ne 0 ] && [ "$overall_status" -eq 0 ]; then
    overall_status="$status"
  fi
}

lean_path_file() {
  local file="$1"
  lake env env | awk -F= '$1 == "LEAN_PATH" { print substr($0, index($0, "=") + 1) }' \
    | tr ':' '\n' \
    | awk 'NF && !seen[$0]++' > "$file"
}

prewarm_lean_path() {
  local label="$1"
  local prefix="$2"
  local dirs="$out_dir/${prefix}-lean-path.txt"
  local files="$out_dir/${prefix}-files.txt"
  local count bytes status start end elapsed

  lean_path_file "$dirs"
  : > "$files"

  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    find "$dir" -type f \( -name '*.olean' -o -name '*.olean.*' -o -name '*.ir' \) -print0 >> "$files"
  done < "$dirs"

  count="$(tr '\0' '\n' < "$files" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" -gt 0 ]; then
    case "$(uname -s)" in
      Darwin)
        bytes="$(xargs -0 stat -f '%z' < "$files" | awk '{ s += $1 } END { print s + 0 }')"
        ;;
      *)
        bytes="$(xargs -0 stat -c '%s' < "$files" | awk '{ s += $1 } END { print s + 0 }')"
        ;;
    esac
  else
    bytes=0
  fi

  echo "==> $label"
  printf 'Prewarming %s files, %s bytes\n' "$count" "$bytes"

  start="$(date +%s)"
  set +e
  if [ "$count" -gt 0 ]; then
    xargs -0 cat < "$files" > /dev/null
    status="$?"
  else
    status=0
  fi
  set -e
  end="$(date +%s)"
  elapsed="$((end - start))"

  append_summary "### $label"
  append_summary
  append_summary '```text'
  printf 'lean_path_dirs=%s\n' "$(wc -l < "$dirs" | tr -d ' ')" >> "$summary"
  printf 'artifact_files=%s\n' "$count" >> "$summary"
  printf 'artifact_bytes=%s\n' "$bytes" >> "$summary"
  printf 'elapsed_seconds=%s\n' "$elapsed" >> "$summary"
  printf 'exit_status=%s\n' "$status" >> "$summary"
  append_summary '```'
  append_summary

  if [ "$status" -ne 0 ] && [ "$overall_status" -eq 0 ]; then
    overall_status="$status"
  fi
}

cleanup() {
  if [ -n "$ramdisk_device" ]; then
    hdiutil detach "$ramdisk_device" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

run_macos_ramdisk() {
  local ramdisk_mb="${RAMDISK_MB:-6144}"
  local ramdisk_name="LeanImportRAMDisk$$"
  local mount_point="/Volumes/$ramdisk_name"
  local sectors
  local copy_log="$out_dir/macos-ramdisk-copy.log"
  local copy_status

  append_summary "### macOS RAM disk setup"
  append_summary
  append_summary '```text'
  du -sh . .lake >> "$summary" 2>&1 || true
  printf 'ramdisk_mb=%s\n' "$ramdisk_mb" >> "$summary"
  append_summary '```'
  append_summary

  sectors="$((ramdisk_mb * 2048))"
  ramdisk_device="$(hdiutil attach -nomount "ram://$sectors")"
  diskutil erasevolume APFS "$ramdisk_name" "$ramdisk_device" > "$out_dir/macos-ramdisk-erase.log"

  set +e
  rsync -a --exclude '.git' --exclude 'experiment-out' ./ "$mount_point/repo/" > "$copy_log" 2>&1
  copy_status="$?"
  set -e

  append_summary "### macOS RAM disk copy"
  append_summary
  append_summary '```text'
  printf 'exit_status=%s\n' "$copy_status" >> "$summary"
  du -sh "$mount_point/repo" >> "$summary" 2>&1 || true
  tail -80 "$copy_log" >> "$summary" || true
  append_summary '```'
  append_summary

  if [ "$copy_status" -ne 0 ]; then
    echo "RAM disk copy failed; skipping RAM disk run" >&2
    return 0
  fi

  (
    cd "$mount_point/repo"
    time_command "macOS RAM disk bare Mathlib import run" "macos-ramdisk-run" \
      lake env lean --run CI/MathlibImportNoop.lean
  )
}

append_summary "## Mathlib Import Cache Experiments"
append_summary
append_summary '```text'
printf 'mode=%s\n' "$mode" >> "$summary"
printf 'uname=%s\n' "$(uname -a)" >> "$summary"
lean --version >> "$summary"
lake --version >> "$summary"
append_summary '```'
append_summary

case "$mode" in
  macos)
    time_command "macOS baseline bare Mathlib import run" "macos-baseline-run" \
      lake env lean --run CI/MathlibImportNoop.lean
    time_command "macOS second bare Mathlib import run" "macos-second-run" \
      lake env lean --run CI/MathlibImportNoop.lean
    prewarm_lean_path "macOS explicit LEAN_PATH prewarm" "macos-prewarm"
    time_command "macOS after explicit prewarm bare Mathlib import run" "macos-after-prewarm-run" \
      lake env lean --run CI/MathlibImportNoop.lean
    run_macos_ramdisk
    ;;
  linux)
    time_command "Linux warm bare Mathlib import run" "linux-warm-run" \
      lake env lean --run CI/MathlibImportNoop.lean
    append_summary "### Linux drop page cache"
    append_summary
    append_summary '```text'
    set +e
    sudo sync >> "$summary" 2>&1
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' >> "$summary" 2>&1
    drop_status="$?"
    set -e
    printf 'exit_status=%s\n' "$drop_status" >> "$summary"
    append_summary '```'
    append_summary
    if [ "$drop_status" -ne 0 ] && [ "$overall_status" -eq 0 ]; then
      overall_status="$drop_status"
    fi
    time_command "Linux after drop_caches bare Mathlib import run" "linux-after-drop-caches-run" \
      lake env lean --run CI/MathlibImportNoop.lean
    prewarm_lean_path "Linux explicit LEAN_PATH prewarm" "linux-prewarm"
    time_command "Linux after explicit prewarm bare Mathlib import run" "linux-after-prewarm-run" \
      lake env lean --run CI/MathlibImportNoop.lean
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

exit "$overall_status"
