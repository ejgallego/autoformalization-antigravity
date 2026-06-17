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
2. `lake build VersoBlueprint`
3. `lake build DominoPuzzleProof.TeXPrelude`
4. `lake build DominoPuzzleProof.Chapters.DominoPuzzleProof`
5. `lake build DominoPuzzleProof`
6. `lake build`
7. `lake env lean --run BlueprintMain.lean`
8. `lake build blueprint-gen`
9. `.lake/build/bin/blueprint-gen`

The standard build remains covered by the split target sequence and a final `lake build` check, and Mathlib cache retrieval is an explicit measured step. Each timed command prints process snapshots every 60 seconds while it is running.

Manual dispatch inputs:

- `timing_threshold_seconds`: override the default 60 second failure threshold.
- `ssh_debug`: open a short-lived tmate SSH session after setup/cache retrieval and before the build steps.

## First macOS Observation

Run `27720072576` on 2026-06-17 was cancelled after the standard build finished but before executable timing completed:

- `lake exe cache get`: 232 seconds.
- `lake build`: 596 seconds.
- Within `lake build`, `DominoPuzzleProof.Chapters.DominoPuzzleProof` took 238 seconds.
- Within `lake build`, `DominoPuzzleProof` took 130 seconds.
- A later split run showed `lake build blueprint-gen` was slow enough to block reaching the `lean --run` timing, so the workflow now runs `lean --run` before executable build comparison.

This suggests the next useful split is project-module timing, not just whole-build timing.

## If macOS Is Slow

1. Rerun the workflow once to rule out runner noise or cache warmup effects.
2. Compare runner context from the log: macOS version, CPU, Lean version, Lake version, and the manifest revisions.
3. Use the timing summary to classify the slow phase:
   - `lake exe cache get`: dependency checkout, cache executable build, or Mathlib cache download.
   - `lake build VersoBlueprint`: Verso/SubVerso/VersoBlueprint compilation after Mathlib cache retrieval.
   - `lake build DominoPuzzleProof.Chapters.DominoPuzzleProof`: chapter document elaboration.
   - `lake build DominoPuzzleProof`: main manual elaboration and rendering-related elaboration.
   - Final `lake build`: confirmation that the split target sequence covered the standard build.
   - `lake env lean --run BlueprintMain.lean`: Lean interpreter startup or module loading.
   - `lake build blueprint-gen`: executable-specific compilation/linking.
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
