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
8. Optionally, on manual dispatch only, `lake build blueprint-gen`
9. Optionally, on manual dispatch only, `.lake/build/bin/blueprint-gen`

The standard build remains covered by the split target sequence and a final `lake build` check, and Mathlib cache retrieval is an explicit measured step. Each timed command prints process snapshots every 60 seconds while it is running.

The workflow restores and saves a non-mathlib Lake cache with a primary key derived from `runner.os`, `runner.arch`, dependency files, and project Lean sources. It caches package sources plus non-mathlib build artifacts, but intentionally does not cache `mathlib/.lake/build`; mathlib artifacts are fetched by the explicit `lake exe cache get` step. The cache has dependency-level restore fallbacks so source-only edits can start from the expensive Verso/dependency build cache while saving a fresh source-specific cache after a successful standard build.

The save happens immediately after the final standard `lake build` check and before the intentionally failing `lean --run` threshold step, so repeated debugging runs can reuse the expensive setup/build work.

Manual dispatch inputs:

- `timing_threshold_seconds`: override the default 60 second failure threshold.
- `ssh_debug`: open a short-lived tmate SSH session after setup/cache retrieval and before the build steps.
- `build_executable`: also build and time the compiled blueprint executable as a comparison path.

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

Run `27725050908` verified the earlier full `.lake` cache:

- Cache hit: `lake-macOS-ARM64-bf841b6917025e996a8033309fc5bfcd9c70feaee894da293728819347c07217`.
- Restored cache size: about 2.5 GB.
- `lake exe cache get`: 24 seconds.
- `lake build VersoBlueprint`: 2 seconds.
- `lake build DominoPuzzleProof.Chapters.DominoPuzzleProof`: 8 seconds.
- `lake build DominoPuzzleProof`: 12 seconds.
- Final `lake build`: 8 seconds.
- `lake env lean --run BlueprintMain.lean`: 135 seconds, so the slow runtime signal remains after removing repeated build setup.

That cache removed most repeated setup cost, but it was too large because it included Mathlib build artifacts. The workflow now uses a narrower non-mathlib Lake cache for repeated setup work, while Mathlib artifacts come from `lake exe cache get`.

## Trigger and Repo-Local Fix

The repo-local trigger was `DominoPuzzleProof/Chapters/DominoPuzzleProof.lean` importing bare `Mathlib`. The blueprint runner imports the chapter document, so `lake env lean --run BlueprintMain.lean` had to load and finalize the full mathlib import closure even though the embedded Lean snippets only need `Finset` and finite-sum notation.

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

## Minimal Mathlib Import Repro

The repo-local import narrowing does not explain why macOS was more than two minutes slower than Linux for the full `Mathlib` import closure. The separate manual workflow `.github/workflows/mathlib-import-timing.yml` compares Ubuntu and macOS on the same Lean 4.31.0 toolchain with these probes:

1. `lake build Mathlib`
2. `lake env lean CI/MathlibImportNoop.lean`
3. `lake env lean --run CI/MathlibImportNoop.lean`
4. A second `lake env lean --run CI/MathlibImportNoop.lean`
5. `lake build VersoBlueprint`
6. `lake build DominoPuzzleProof`
7. `lake env lean --run CI/BlueprintWithMathlib.lean`

`CI/MathlibImportNoop.lean` is the smallest bare-`Mathlib` executable. `CI/BlueprintWithMathlib.lean` mirrors `BlueprintMain.lean` but inserts `import Mathlib` first, so it reproduces the old heavy import path without putting that import back into the project library.

Local Linux timings from this checkout:

```text
/usr/bin/time -p lake env lean CI/MathlibImportNoop.lean
real 2.88
user 2.04
sys 0.85

/usr/bin/time -p lake env lean --run CI/MathlibImportNoop.lean
real 6.03
user 2.12
sys 1.27

/usr/bin/time -p lake env lean --run CI/BlueprintWithMathlib.lean
real 4.79
user 3.59
sys 1.23
```

If the macOS matrix leg reproduces the 100s+ behavior on these files, the issue is likely in Lean/mathlib module loading or persistent environment extension finalization on macOS, not in Blueprint generation.

Run `27736289508` reproduced the platform gap on the minimal bare-Mathlib file after `lake build Mathlib`:

- Ubuntu: check 4s, first run 5s, second run 4s.
- macOS: check 112s, first run 117s, second run 111s.
- Ubuntu `CI/BlueprintWithMathlib.lean`: 8s.
- macOS `CI/BlueprintWithMathlib.lean`: 134s.
- macOS `lsof` saw about 10,003 open file entries during the import, including 2,466 `.olean`, 4,931 `.olean.*`, and 2,588 `.ir` files.
- macOS `sample` again pointed at `Lean_importModules` / `Lean_finalizeImport`.

## Syscall and Filesystem Trace

The manual workflow `.github/workflows/mathlib-import-syscall-trace.yml` prepares the same `lake build Mathlib` state and then traces:

```text
lake env lean --run CI/MathlibImportNoop.lean
```

The Ubuntu leg uses `strace` to capture file, mmap, read, close, fcntl, and sync-related syscalls. The macOS leg first tries `dtruss` for the nearest syscall-level comparison, then runs the command again with `fs_usage` filtering plus periodic `lsof`, `vmmap`, and `sample` snapshots. The workflow uploads raw artifacts and prints compact syscall/path summaries to the GitHub job summary.

The main questions for this trace are:

1. Are Linux and macOS opening/mapping the same order of magnitude of `.olean`/`.ir` artifacts?
2. Is macOS issuing unexpected `fsync`/`msync`/fcntl calls or unusual mmap behavior?
3. Does `fs_usage` show page-in or metadata traffic that would explain the large wall-clock/user-time gap?

Run `27797334367` on 2026-06-19 answered the first two questions and strongly points at the third:

- Both legs used Lean 4.31.0 and the same `CI/MathlibImportNoop.lean` command.
- The standard `lake build Mathlib` step was slower on macOS than Ubuntu, but still far below the traced import time: Ubuntu `real 19.53`, macOS `real 47.72`.
- The traced import was Ubuntu `real 49.38` under `strace`, versus macOS `real 155.09` under `fs_usage`.
- Linux's final Lean process had the same order of magnitude of operations as macOS: about 662k `statx`, 42.3k `openat`, 42.3k `read`, 42.3k `mmap`, and 42.3k `close`.
- macOS's final Lean process had about 668k `stat64`, 42.4k `open`, 42.5k `read`, 42.4k `mmap`, 42.3k `fstat64`, and 42.3k `close`.
- Neither trace showed `fsync` or `msync` traffic. Linux mmap lines are overwhelmingly `MAP_PRIVATE`; the macOS `fs_usage` output does not expose mmap flags.
- The standout macOS event is `PAGE_IN_FILE`: about 551k events in the final Lean process, with summed `fs_usage` duration around 118 seconds. The next largest macOS Lean event sums were about 9.5 seconds in `read` and 5.7 seconds in `mmap`.
- The macOS `dtruss -f` probe did not capture the interesting child process on the GitHub runner. It only saw the wrapper process fork and a few `getattrlist` calls, so it is not useful evidence about mmap flags yet.
- Periodic `lsof`/`vmmap`/`sample` again caught the final `lean` process in `Lean_importModules` / `Lean_finalizeImport`, with about 10,003 open files and about 7.4 GB of mapped files across roughly 42k regions.

Working hypothesis after this run: macOS is paying a large file-backed page-fault cost while Lean finalizes the full Mathlib import closure from many private mapped `.olean`/`.ir` artifacts. The syscall volume itself is comparable to Linux, and there is no evidence yet for accidental sync calls.

Follow-up run `27797774363` added resource counters and per-process duration summaries:

- Ubuntu under `strace`: elapsed `1:02.21`, maximum RSS about 6.7 GB, 18 major page faults, and 166,929 minor page faults. The final Lean process again had about 662k `statx` and 42.3k each of `openat`, `read`, `mmap`, and `close`.
- macOS under `fs_usage`: `217.36 real`, maximum RSS about 3.2 GB, 287,936 page reclaims, and 524,387 page faults. `fs_usage` attributed about 520,889 `PAGE_IN_FILE` events to the final Lean process, with summed duration around 154 seconds.
- The macOS final Lean process again had the same syscall-scale operation counts as Linux: about 668k `stat64`, 42.4k `open`, 42.5k `read`, 42.4k `mmap`, 42.3k `fstat64`, and 42.3k `close`.

This strengthens the hypothesis: the macOS-specific cost is page-in/page-fault behavior while touching the mapped import graph, not extra file-open volume or explicit synchronization.

The next trace should be narrower:

1. Use the added low-overhead page-fault counters around the import (`/usr/bin/time -l` on macOS, `/usr/bin/time -v` on Linux) to compare major faults, minor faults, page reclaims, and pageins without rerunning broad tracing.
2. On a tmate runner, attach after the final `lean` process starts instead of tracing the `lake` wrapper, then try to capture real macOS `mmap` flags with `dtruss -p <pid>` or a small DTrace script if GitHub's runner policy allows it.
3. If mmap flags are normal private file mappings, reduce the repro outside this repo to `import Mathlib` plus the Lean 4.31.0/macOS runner context and report it upstream as a module-loading/page-in regression.

The manual `.github/workflows/mathlib-import-macos-attach-trace.yml` workflow automates item 2: it builds the same cached Mathlib state, starts `lake env lean --run CI/MathlibImportNoop.lean`, waits for the final `lean` process, then attaches a narrow DTrace `mmap`/`mmap_extended`/sync probe briefly while collecting `lsof`, `vmmap`, `sample`, and `/usr/bin/time -l` artifacts. It also has an optional `ssh_debug` input if the automated attach cannot capture enough detail.

Run `27798445171` confirmed that automated attach catches the right phase, but `dtruss -p` was still not useful on the GitHub runner:

- The command took `148.33 real`, with max RSS about 3.6 GB, 297,273 page reclaims, and 490,720 page faults.
- Before attach, the target `lean` process had 362 open file entries, 86 `.olean` files, 172 `.olean.*` files, 86 `.ir` files, and about 1.1 GB of mapped files across 5,878 regions.
- After a 45 second attach window, it had 10,003 open file entries, 2,466 `.olean` files, 4,931 `.olean.*` files, 2,588 `.ir` files, and about 7.4 GB of mapped files across 42,187 regions.
- The sampled stack was in `Lean_importModules` / `Lean_finalizeImport`, so the attach window covered module loading and finalization.
- The `dtruss -p` output only reported DTrace dynamic variable drops and no syscall lines, so the follow-up workflow now uses a smaller raw DTrace script instead of `dtruss`.

Run `27798802809` showed that the smaller DTrace probe works:

- The command took `124.92 real`, with max RSS about 3.7 GB, 291,559 page reclaims, and 482,390 page faults.
- DTrace captured 35,756 `mmap` entries and no `mmap_extended` entries during the 45 second attach window.
- The dominant mmap flags were ordinary Darwin file mappings: 31,585 entries with `0x40002` (`MAP_UNIX03 | MAP_PRIVATE`) and 3,337 entries with `0x40001` (`MAP_UNIX03 | MAP_SHARED`). The main anonymous mapping flag was `0x41002` (`MAP_UNIX03 | MAP_ANON | MAP_PRIVATE`), with 686 entries.
- The first DTrace probe also saw 183 `fsync` entries, contradicting the earlier `fs_usage` summary and requiring a return-time check.

Run `27799098281` added sync return timings:

- The command took `153.68 real`, with max RSS about 3.5 GB, 287,856 page reclaims, and 490,193 page faults.
- DTrace captured 37,065 `mmap` entries and no `mmap_extended` entries.
- DTrace captured 432 `fsync` calls and 1 `msync` call, all returning with errno 0.
- Total sync elapsed time was about 66 ms, and the slowest sync call was about 10 ms, so sync calls are not a material cause of the 100s+ wall time.

Current conclusion: macOS uses normal private/shared file mappings with the Darwin `MAP_UNIX03` bit, and sync calls are cheap. The remaining abnormal signal is still file-backed paging: hundreds of thousands of page faults/page reclaims and earlier `fs_usage` `PAGE_IN_FILE` duration while finalizing the full Mathlib import closure.

The manual `.github/workflows/mathlib-import-cache-experiments.yml` workflow tests the next page-cache hypotheses without broad tracing:

1. macOS baseline and immediate second `lake env lean --run CI/MathlibImportNoop.lean` runs.
2. Explicitly reading all `LEAN_PATH` `.olean`, `.olean.*`, and `.ir` artifacts, then rerunning the bare Mathlib import.
3. Copying the built checkout to a macOS APFS RAM disk and rerunning from there.
4. Ubuntu warm, post-`drop_caches`, and explicit-prewarm runs for comparison.

Runs `27820837960`, `27821727814`, and `27822430217` added the cache/prewarm data:

- Ubuntu stayed fast when warm: about 5-6 seconds for `lake env lean --run CI/MathlibImportNoop.lean`.
- After Linux `drop_caches`, the same command rose only to 27-34 seconds, with about 62k major faults and about 13-14 million filesystem input units. Explicitly reading the 69,484 `LEAN_PATH` `.olean*`/`.ir` files, about 7.9 GB, then restored the run to about 5-6 seconds.
- macOS remained slow across repeated warm runs: representative timings were 157 seconds, then 118 seconds, then 127 seconds after explicit prewarm. Another runner showed 227 seconds, 194 seconds, then 220 seconds after explicit prewarm.
- The explicit macOS prewarm did read the same 69,484 artifacts, about 7.9 GB, in 35-54 seconds, but it did not reduce the following import run to Linux-like times.
- A 9 GiB APFS RAM disk successfully held a copied 6.7 GiB checkout. Running `lean --run CI/MathlibImportNoop.lean` directly with a translated `LEAN_PATH` from that RAM-disk copy still took 196 seconds, with 1,264,459 page faults and no block input operations.

Updated conclusion: this is not explained by cold physical disk I/O or by Lake process overhead alone. Linux cold-cache behavior is much cheaper and explicit prewarm restores Linux performance, while macOS remains slow even after explicit prewarm and when the artifacts are served from a RAM-backed filesystem. The RAM-disk run adds memory pressure, so it is not a clean lower-bound benchmark, but it is strong evidence that the abnormal cost is in macOS VM/file-mapping/page-fault behavior or Lean's mapped-import access pattern on macOS.

The manual `.github/workflows/mathlib-import-version-curve.yml` workflow tests two additional axes:

1. Lean/mathlib version pairs including `v4.27.0`, `v4.30.0`, and `v4.31.0`, plus a `mathlib-master` row that reads mathlib's current `lean-toolchain`.
2. An import-size curve from `Init` through narrow Mathlib modules, `Mathlib.Tactic`, and the full `Mathlib` umbrella.

Run `27823586757` on 2026-06-19 completed the version/import curve:

- Ubuntu stayed stable across all tested versions: full `import Mathlib` took 4.96 seconds on Lean/mathlib `v4.30.0`, 4.75 seconds on `v4.31.0`, and 4.85 seconds on current `mathlib-master`.
- macOS was slow on both release tags: full `import Mathlib` took 171.91 seconds on `v4.30.0` and 190.07 seconds on `v4.31.0`.
- `mathlib-master` used Lean `4.32.0-rc1` at commit `b4812ae53eea93439ad5dce5a5c26591c31cb697`; macOS improved to 114.18 seconds, but that is still about 23x slower than Ubuntu on the same row.
- The smaller imports are already slower on macOS but do not explain the full gap: `Mathlib.Tactic` took 26-30 seconds on macOS versus 2.6-3.1 seconds on Ubuntu, while narrow Finset-related imports stayed in the 4-13 second range on macOS.
- The import curve is not a strict cold-cache size curve because the workflow runs import probes sequentially. Earlier probes warm dependencies for later probes, so the final `Mathlib` result is especially notable: it remains 100s+ even after the smaller imports ran first.
- macOS `Mathlib` resource counters were again VM-heavy: `v4.31.0` reported 190.07 real, 23.75 user, 42.91 sys, about 3.9 GB max RSS, 316k page reclaims, and 392k page faults. Ubuntu `v4.31.0` reported 4.75 real, 2.73 user, 2.02 sys, about 6.7 GB max RSS, 160k minor faults, and zero major faults.
- One `v4.31.0` macOS nuance: `lake exe cache get` reported 26 cache misses and `lake build Mathlib` rebuilt Batteries/Mathlib artifacts in 77 seconds. This affected total job time, but not the standalone `lake env lean --run ImportCurve/Mathlib.lean` result, which was timed after the build completed.

Updated conclusion after the version curve: the pathology exists in Lean 4.30 and 4.31 on macOS, and current Lean/mathlib master appears materially better but still far from Linux behavior. The next useful experiments are:

1. Bisect between Lean `4.31.0` commit `68218e876d2a38b1985b8590fff244a83c321783` and Lean `4.32.0-rc1` commit `b4812ae53eea93439ad5dce5a5c26591c31cb697`, using matching mathlib commits when available, to find the change that reduced macOS full-import time from about 190 seconds to about 114 seconds.
2. Generate a top-level `Mathlib.lean` prefix/import bisection on macOS, so we can tell whether the 100s+ jump comes from a specific imported area or scales with the aggregate number of mapped `.olean`/`.ir` artifacts and persistent extensions.
3. For the heaviest prefix found by that bisection, repeat the attach trace and resource counters to compare page faults, `PAGE_IN_FILE`, mapped region count, and finalization samples against the full umbrella import.

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
