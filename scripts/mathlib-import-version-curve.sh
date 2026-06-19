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

summary="$out_dir/version-curve-summary.md"
: > "$summary"

mathlib_ref="${MATHLIB_REF:-v4.31.0}"
project_dir="${IMPORT_CURVE_PROJECT_DIR:-${RUNNER_TEMP:-/tmp}/mathlib-import-curve-$label}"
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

  append_summary "### $label_text"
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

write_import_file() {
  local name="$1"
  local module="$2"
  local file="$project_dir/ImportCurve/${name}.lean"

  {
    printf 'import %s\n\n' "$module"
    printf 'def main : IO Unit := pure ()\n'
  } > "$file"
}

rm -rf "$project_dir"
mkdir -p "$project_dir/ImportCurve"

{
  printf 'leanprover/lean4:%s\n' "$LEAN_VERSION_TAG"
} > "$project_dir/lean-toolchain"

{
  printf 'name = "ImportCurve"\n'
  printf 'version = "0.1.0"\n'
  printf 'defaultTargets = ["ImportCurve"]\n\n'
  printf '[[require]]\n'
  printf 'name = "mathlib"\n'
  printf 'scope = "leanprover-community"\n'
  printf 'git = "https://github.com/leanprover-community/mathlib4"\n'
  printf 'rev = "%s"\n\n' "$mathlib_ref"
  printf '[[lean_lib]]\n'
  printf 'name = "ImportCurve"\n'
} > "$project_dir/lakefile.toml"

write_import_file "Init" "Init"
write_import_file "NatBasic" "Mathlib.Data.Nat.Basic"
write_import_file "FinsetBasic" "Mathlib.Data.Finset.Basic"
write_import_file "BigOperatorsFinset" "Mathlib.Algebra.BigOperators.Group.Finset.Basic"
write_import_file "Tactic" "Mathlib.Tactic"
write_import_file "Mathlib" "Mathlib"

append_summary "## Mathlib Import Version Curve: $label"
append_summary
append_summary '```text'
printf 'label=%s\n' "$label" >> "$summary"
printf 'mathlib_ref=%s\n' "$mathlib_ref" >> "$summary"
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

(
  cd "$project_dir"
  time_command "Lake update ($label)" "lake-update" lake update
  time_command "Mathlib cache retrieval ($label)" "mathlib-cache" lake exe cache get
  time_command "Mathlib umbrella build ($label)" "mathlib-build" lake build Mathlib

  while IFS='|' read -r prefix title path; do
    time_command "$title ($label)" "$prefix" lake env lean --run "$path"
  done <<'EOF'
import-init|Import Init|ImportCurve/Init.lean
import-nat-basic|Import Mathlib.Data.Nat.Basic|ImportCurve/NatBasic.lean
import-finset-basic|Import Mathlib.Data.Finset.Basic|ImportCurve/FinsetBasic.lean
import-bigoperators-finset|Import Mathlib.Algebra.BigOperators.Group.Finset.Basic|ImportCurve/BigOperatorsFinset.lean
import-tactic|Import Mathlib.Tactic|ImportCurve/Tactic.lean
import-mathlib|Import Mathlib umbrella|ImportCurve/Mathlib.lean
EOF
)

exit "$overall_status"
