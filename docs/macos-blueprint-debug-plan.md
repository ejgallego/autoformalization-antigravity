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

The workflow restores and saves `.lake` with a primary key derived from `runner.os`, `runner.arch`, dependency files, and project Lean sources. It also has dependency-level restore fallbacks so source-only edits can start from the expensive dependency build cache while saving a fresh source-specific cache after a successful standard build.

The save happens immediately after the final standard `lake build` check and before the intentionally failing `lean --run` threshold step, so repeated debugging runs can reuse the expensive setup/build work.

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

Run `27722404967` on 2026-06-17 confirmed the reported slow command on macOS with Lean 4.31.0:

- Lean: `4.31.0`, `arm64-apple-darwin24.6.0`.
- `lake exe cache get`: 168 seconds.
- `lake build VersoBlueprint`: 220 seconds.
- `lake build DominoPuzzleProof.Chapters.DominoPuzzleProof`: 263 seconds.
- `lake build DominoPuzzleProof`: 172 seconds.
- Final `lake build`: 26 seconds.
- `lake env lean --run BlueprintMain.lean`: 147 seconds, failing the 60 second threshold.
- During `lean --run`, the `lean` process used about 50.8% memory but only about 10-18% CPU in snapshots, suggesting waiting, paging, or I/O rather than pure CPU saturation.

Run `27725050908` verified the `.lake` cache:

- Cache hit: `lake-macOS-ARM64-bf841b6917025e996a8033309fc5bfcd9c70feaee894da293728819347c07217`.
- Restored cache size: about 2.5 GB.
- `lake exe cache get`: 24 seconds.
- `lake build VersoBlueprint`: 2 seconds.
- `lake build DominoPuzzleProof.Chapters.DominoPuzzleProof`: 8 seconds.
- `lake build DominoPuzzleProof`: 12 seconds.
- Final `lake build`: 8 seconds.
- `lake env lean --run BlueprintMain.lean`: 135 seconds, so the slow runtime signal remains after removing repeated build setup.

The cache removes most repeated setup cost. The remaining investigation should focus on why `lean --run` spends more than two minutes after the project is already built.

## Root Cause and Fix

The slow path was caused by `DominoPuzzleProof/Chapters/DominoPuzzleProof.lean` importing bare `Mathlib`. The blueprint runner imports the chapter document, so `lake env lean --run BlueprintMain.lean` had to load and finalize the full mathlib import closure even though the embedded Lean snippets only need `Finset` and finite-sum notation.

A tmate session on the same macOS worker as run `27726851856` measured:

- Before narrowing the import: `real 181.46`, `user 15.96`, `sys 37.92`.
- During the run, `lean` reached about 3.6 GB RSS with low CPU.
- `lsof` for the process showed about 10,000 open file entries, including 7,421 `.olean*` files and 2,564 `.ir` files, mostly from mathlib.
- `sample` pointed at `Lean_importModules` / `Lean_finalizeImport`, especially persistent environment extension finalization.

Replacing `import Mathlib` with:

```lean
import Mathlib.Algebra.BigOperators.Group.Finset.Basic
import Mathlib.Data.Finset.Basic
```

keeps the project build working and reduced the same macOS worker's `lake env lean --run BlueprintMain.lean` runtime to `real 8.90`, `user 3.70`, `sys 4.79`.

The Linux checkout also remains fast after the change:

```text
/usr/bin/time -p lake env lean --run BlueprintMain.lean
real 3.37
user 2.76
sys 0.63
```

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
4. Inspect the `sample` output from the `BlueprintMain via lean --run` step. If it points at filesystem access, module deserialization, or runtime rendering, add a narrower probe for that path.
5. Re-run manually with `ssh_debug: true` and inspect the live worker:
   - `time lake env lean --run BlueprintMain.lean`
   - `ps -ef | grep '[l]ean'`
   - `sample <pid> 10`
   - `lsof -p <pid>`
   - `vmmap <pid> | head -80`
6. If the slow path is specific to `lean --run`, compare it against the compiled executable path and then bisect imports in a throwaway branch between `BlueprintMain.lean`, `VersoManual`, `VersoBlueprint.PreviewManifest`, and `DominoPuzzleProof`.
7. If the slow path is in file or process startup, collect a short `fs_usage` sample from the SSH session and compare it with Linux file access patterns.
8. Keep SSH runs manual only; do not leave persistent debug services enabled outside `workflow_dispatch`.
