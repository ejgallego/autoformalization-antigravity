#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <out-dir> <label>" >&2
  exit 2
fi

out_dir="$1"
label="$2"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

summary="$out_dir/prefix-bisect-summary.md"
results="$out_dir/prefix-results.tsv"
: > "$summary"
printf 'count\telapsed_seconds\texit_status\tfirst_module\tlast_module\tlast_group\n' > "$results"

mathlib_ref="${MATHLIB_REF:-v4.31.0}"
threshold_seconds="${PREFIX_THRESHOLD_SECONDS:-60}"
max_bisect_steps="${PREFIX_MAX_BISECT_STEPS:-14}"
probe_counts="${PREFIX_PROBE_COUNTS:-1 2 4 8 16 32 64 128 256 512 1024 2048 4096}"
project_dir="${PREFIX_PROJECT_DIR:-${RUNNER_TEMP:-/tmp}/mathlib-prefix-bisect-$label}"
overall_status=0
last_elapsed=0
last_status=0

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
  local start end status

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
  last_elapsed="$((end - start))"
  last_status="$status"

  printf '%s\n' "$status" > "$status_file"
  printf '%s\n' "$last_elapsed" > "$elapsed_file"

  append_summary "### $label_text"
  append_summary
  append_summary '```text'
  print_command "$@" >> "$summary"
  printf 'elapsed_seconds=%s\n' "$last_elapsed" >> "$summary"
  printf 'exit_status=%s\n' "$status" >> "$summary"
  cat "$time_log" >> "$summary" || true
  append_summary '```'
  append_summary

  if [ "$status" -ne 0 ] && [ "$overall_status" -eq 0 ]; then
    overall_status="$status"
  fi
}

module_group() {
  local module="$1"
  case "$module" in
    Mathlib.*)
      module="${module#Mathlib.}"
      printf '%s\n' "${module%%.*}"
      ;;
    *)
      printf '%s\n' "$module"
      ;;
  esac
}

rm -rf "$project_dir"
mkdir -p "$project_dir/ImportPrefix"

{
  printf 'leanprover/lean4:%s\n' "$LEAN_VERSION_TAG"
} > "$project_dir/lean-toolchain"

{
  printf 'name = "ImportPrefix"\n'
  printf 'version = "0.1.0"\n'
  printf 'defaultTargets = ["ImportPrefix"]\n\n'
  printf '[[require]]\n'
  printf 'name = "mathlib"\n'
  printf 'scope = "leanprover-community"\n'
  printf 'git = "https://github.com/leanprover-community/mathlib4"\n'
  printf 'rev = "%s"\n\n' "$mathlib_ref"
  printf '[[lean_lib]]\n'
  printf 'name = "ImportPrefix"\n'
} > "$project_dir/lakefile.toml"

append_summary "## Mathlib Prefix Bisect: $label"
append_summary
append_summary '```text'
printf 'label=%s\n' "$label" >> "$summary"
printf 'mathlib_ref=%s\n' "$mathlib_ref" >> "$summary"
printf 'threshold_seconds=%s\n' "$threshold_seconds" >> "$summary"
printf 'max_bisect_steps=%s\n' "$max_bisect_steps" >> "$summary"
printf 'project_dir=%s\n' "$project_dir" >> "$summary"
printf 'uname=%s\n' "$(uname -a)" >> "$summary"
lean --version >> "$summary"
lake --version >> "$summary"
append_summary '```'
append_summary

append_summary "### Project"
append_summary
append_summary '```toml'
cat "$project_dir/lakefile.toml" >> "$summary"
append_summary '```'
append_summary

pushd "$project_dir" > /dev/null
time_command "Lake update ($label)" "lake-update" lake update
time_command "Mathlib cache retrieval ($label)" "mathlib-cache" lake exe cache get
time_command "Mathlib umbrella build ($label)" "mathlib-build" lake build Mathlib
popd > /dev/null

mathlib_file="$project_dir/.lake/packages/mathlib/Mathlib.lean"
if [ ! -f "$mathlib_file" ]; then
  echo "cannot find $mathlib_file" >&2
  exit 1
fi

imports_file="$out_dir/mathlib-imports.txt"
awk '/^(public[[:space:]]+)?import[[:space:]]+/ {print $NF}' "$mathlib_file" > "$imports_file"
total_imports="$(wc -l < "$imports_file" | tr -d ' ')"

append_summary "### Mathlib import list"
append_summary
append_summary '```text'
printf 'total_imports=%s\n' "$total_imports" >> "$summary"
awk '
  {
    mod=$1
    group=mod
    if (mod ~ /^Mathlib[.]/) {
      sub(/^Mathlib[.]/, "", group)
      sub(/[.].*$/, "", group)
    }
    if (NR == 1) {
      prev=group
    } else if (group != prev) {
      printf "%s\t%d\n", prev, NR - 1
      prev=group
    }
  }
  END {
    if (NR > 0) {
      printf "%s\t%d\n", prev, NR
    }
  }
' "$imports_file" >> "$summary"
append_summary '```'
append_summary

run_prefix() {
  local count="$1"
  local prefix_name elapsed_file status_file first_module last_module last_group file

  if [ "$count" -lt 1 ]; then
    count=1
  fi
  if [ "$count" -gt "$total_imports" ]; then
    count="$total_imports"
  fi

  prefix_name="prefix-$count"
  elapsed_file="$out_dir/${prefix_name}.elapsed"
  status_file="$out_dir/${prefix_name}.status"

  if [ -f "$elapsed_file" ] && [ -f "$status_file" ]; then
    last_elapsed="$(cat "$elapsed_file")"
    last_status="$(cat "$status_file")"
    return 0
  fi

  file="$project_dir/ImportPrefix/Prefix$count.lean"
  awk -v n="$count" 'NR <= n {printf "import %s\n", $0}' "$imports_file" > "$file"
  printf '\ndef main : IO Unit := pure ()\n' >> "$file"

  first_module="$(sed -n '1p' "$imports_file")"
  last_module="$(sed -n "${count}p" "$imports_file")"
  last_group="$(module_group "$last_module")"

  pushd "$project_dir" > /dev/null
  time_command "Import first $count of $total_imports Mathlib imports ($label)" "$prefix_name" lake env lean --run "ImportPrefix/Prefix$count.lean"
  popd > /dev/null

  last_elapsed="$(cat "$elapsed_file")"
  last_status="$(cat "$status_file")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$count" "$last_elapsed" "$last_status" "$first_module" "$last_module" "$last_group" >> "$results"
}

counts_file="$out_dir/requested-counts.txt"
{
  for count in $probe_counts; do
    printf '%s\n' "$count"
  done
  printf '%s\n' "$total_imports"
} | awk -v total="$total_imports" '
  /^[0-9]+$/ {
    if ($1 >= 1 && $1 <= total) print $1
  }
' | sort -n -u > "$counts_file"

while IFS= read -r count; do
  run_prefix "$count"
done < "$counts_file"

full_elapsed="$(cat "$out_dir/prefix-$total_imports.elapsed")"
append_summary "### Bisection"
append_summary
append_summary '```text'
printf 'full_elapsed_seconds=%s\n' "$full_elapsed" >> "$summary"
printf 'threshold_seconds=%s\n' "$threshold_seconds" >> "$summary"

if [ "$full_elapsed" -lt "$threshold_seconds" ]; then
  printf 'status=full-import-below-threshold\n' >> "$summary"
else
  low=0
  high="$total_imports"
  while IFS=$'\t' read -r count elapsed status first_module last_module last_group; do
    if [ "$count" = "count" ]; then
      continue
    fi
    if [ "$status" -eq 0 ] && [ "$elapsed" -lt "$threshold_seconds" ] && [ "$count" -gt "$low" ]; then
      low="$count"
    fi
    if [ "$status" -eq 0 ] && [ "$elapsed" -ge "$threshold_seconds" ] && [ "$count" -lt "$high" ]; then
      high="$count"
    fi
  done < "$results"

  step=0
  while [ $((high - low)) -gt 1 ] && [ "$step" -lt "$max_bisect_steps" ]; do
    mid=$(((low + high) / 2))
    run_prefix "$mid"
    if [ "$last_status" -eq 0 ] && [ "$last_elapsed" -lt "$threshold_seconds" ]; then
      low="$mid"
    else
      high="$mid"
    fi
    step=$((step + 1))
  done

  high_module="$(sed -n "${high}p" "$imports_file")"
  low_module=""
  if [ "$low" -gt 0 ]; then
    low_module="$(sed -n "${low}p" "$imports_file")"
  fi
  printf 'status=threshold-crossing-estimated\n' >> "$summary"
  printf 'below_count=%s\n' "$low" >> "$summary"
  printf 'below_module=%s\n' "$low_module" >> "$summary"
  printf 'above_count=%s\n' "$high" >> "$summary"
  printf 'above_module=%s\n' "$high_module" >> "$summary"
  printf 'above_group=%s\n' "$(module_group "$high_module")" >> "$summary"
  printf 'bisect_steps=%s\n' "$step" >> "$summary"
fi
append_summary '```'
append_summary

append_summary "### Prefix Results"
append_summary
append_summary '```text'
sort -n -k1,1 "$results" >> "$summary"
append_summary '```'
append_summary

exit "$overall_status"
