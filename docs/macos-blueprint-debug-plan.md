# macOS Blueprint Timing Debug Plan

Goal: isolate why `lake env lean --run BlueprintMain.lean` can be slow on macOS after a normal cached build.

Baseline from this Linux checkout on 2026-06-17 after `lake build`:

```text
/usr/bin/time -p lake env lean --run BlueprintMain.lean
real 4.75
user 3.54
sys 1.21
```

Treat a post-build macOS runtime above 60 seconds as abnormal until we have better data.

## CI Signal

The `.github/workflows/macos-blueprint.yml` workflow runs on `macos-latest`, installs the Lean toolchain with `leanprover/lean-action@v1`, then times each relevant phase explicitly:

1. `lake exe cache get`
2. `lake build`
3. `lake build blueprint-gen`
4. `lake env lean --run BlueprintMain.lean`
5. `.lake/build/bin/blueprint-gen`

The standard build remains `lake build`, and Mathlib cache retrieval is an explicit measured step.

Manual dispatch inputs:

- `timing_threshold_seconds`: override the default 60 second failure threshold.
- `ssh_debug`: open a short-lived tmate SSH session after the build and before the timing step.

## If macOS Is Slow

1. Rerun the workflow once to rule out runner noise or cache warmup effects.
2. Compare runner context from the log: macOS version, CPU, Lean version, Lake version, and the manifest revisions.
3. Use the timing summary to classify the slow phase:
   - `lake exe cache get`: dependency checkout, cache executable build, or Mathlib cache download.
   - `lake build`: Verso/SubVerso/project compilation after Mathlib cache retrieval.
   - `lake build blueprint-gen`: executable-specific compilation/linking.
   - `lake env lean --run BlueprintMain.lean`: Lean interpreter startup or module loading.
   - `.lake/build/bin/blueprint-gen`: generated executable runtime.
4. Re-run manually with `ssh_debug: true` and inspect the live worker:
   - `time lake env lean --run BlueprintMain.lean`
   - `ps -ef | grep '[l]ean'`
   - `sample <pid> 10`
   - `lsof -p <pid>`
   - `vmmap <pid> | head -80`
5. If the slow path is specific to `lean --run`, compare it against the compiled executable path and then bisect imports in a throwaway branch between `BlueprintMain.lean`, `VersoManual`, `VersoBlueprint.PreviewManifest`, and `DominoPuzzleProof`.
6. If the slow path is in file or process startup, collect a short `fs_usage` sample from the SSH session and compare it with Linux file access patterns.
7. Keep SSH runs manual only; do not leave persistent debug services enabled outside `workflow_dispatch`.
