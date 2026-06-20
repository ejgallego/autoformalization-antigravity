# Draft Upstream Report: macOS full Mathlib import is much slower than Linux

Status: draft only. Do not submit or discuss upstream without explicit approval.

## Possible Title

macOS: full `import Mathlib` is 20-35x slower than Linux, apparently due to file-backed mmap page-in/reclaim during import finalization

## Summary

A minimal Lean executable containing only `import Mathlib` is consistently much slower on GitHub-hosted macOS runners than on GitHub-hosted Ubuntu runners after the Mathlib cache has been fetched and `lake build Mathlib` has completed.

Representative timing for:

```lean
import Mathlib

def main : IO Unit := pure ()
```

run as:

```bash
lake exe cache get
lake build Mathlib
lake env lean --run CI/MathlibImportNoop.lean
```

On Lean/mathlib `v4.31.0`, the final import run is about 5 seconds on Ubuntu but 135-170 seconds on macOS. The slow phase samples inside `Lean_importModules` / `Lean_finalizeImport`.

The evidence so far suggests this is not caused by extra syscall volume, explicit sync calls, Lake overhead, or physical disk I/O. The strongest signal is macOS VM behavior around file-backed mmap pages while Lean finalizes the full Mathlib import closure.

## Environment

Repo used for the investigation:

```text
https://github.com/ejgallego/autoformalization-antigravity
lean-toolchain: leanprover/lean4:v4.31.0
mathlib rev: v4.31.0
minimal repro file: CI/MathlibImportNoop.lean
```

GitHub Actions runners used in the main comparison:

| OS | Lean | Runner context | Import time |
| --- | --- | --- | --- |
| Ubuntu | `4.31.0`, `x86_64-unknown-linux-gnu` | Ubuntu 24.04, Linux 6.17 Azure runner | 5.35s |
| macOS latest | `4.31.0`, `arm64-apple-darwin24.6.0` | macOS 15.7.7, Apple M1 virtual runner | 168.48s |
| macOS 26 | `4.31.0`, `arm64-apple-darwin24.6.0` | macOS 26.4, Apple M1 virtual runner | 134.86s |

Main memory-pressure run:

```text
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27876818780
```

## Expected Behavior

After `lake exe cache get` and `lake build Mathlib`, a minimal full-umbrella `import Mathlib` executable should not be 20-35x slower on macOS than on Linux, especially when there is no reported block input and the cache is already present.

## Actual Behavior

From run `27876818780`:

| OS | real | user | sys | max RSS | faults / reclaims | I/O |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| Ubuntu | 5.35s | 2.96s | 2.31s | 6.7 GB | 166,893 minor faults, 0 major faults | 0 filesystem input |
| macOS 26.4 | 134.86s | 13.06s | 17.38s | 3.9 GB | 304,191 page reclaims, 445,995 page faults | 0 block input |
| macOS 15.7.7 | 168.48s | 15.76s | 32.23s | 3.8 GB | 302,516 page reclaims, 460,277 page faults | 0 block input |

Global VM counter deltas from the same run:

| OS | VM deltas |
| --- | --- |
| Ubuntu | about 172k `pgfault`, 1 `pgmajfault`, 40 `pgpgin`; `pgscan`, `pgsteal`, and `workingset_refault_*` stayed at zero |
| macOS 26.4 | about 2.25M translation faults, 521k `Pageins`, 663k page reactivations, 84k compressions, 71k decompressions |
| macOS 15.7.7 | about 2.90M translation faults, 580k `Pageins`, 652k page reactivations, 159k compressions, 125k decompressions |

Periodic process snapshots show the macOS `lean` process around 3.4-3.7 GB RSS and often only 10-40% CPU. The Ubuntu `lean` process reaches about 6.7 GB RSS and runs near full CPU during its short import.

## Additional Evidence

### Syscall counts are similar

The syscall/filesystem trace run:

```text
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27797334367
```

showed similar syscall scale between Linux and macOS for the final Lean process:

| OS | Approximate final Lean process operations |
| --- | --- |
| Linux | 662k `statx`, 42.3k `openat`, 42.3k `read`, 42.3k `mmap`, 42.3k `close` |
| macOS | 668k `stat64`, 42.4k `open`, 42.5k `read`, 42.4k `mmap`, 42.3k `fstat64`, 42.3k `close` |

The standout macOS event was `PAGE_IN_FILE`: about 551k events in the final Lean process, with summed `fs_usage` duration around 118 seconds.

### mmap flags and sync calls look normal

Attach/DTrace runs:

```text
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27798802809
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27799098281
```

captured normal Darwin file mappings:

- Dominant flags were ordinary `MAP_UNIX03 | MAP_PRIVATE` and `MAP_UNIX03 | MAP_SHARED` mappings.
- No `mmap_extended` traffic was seen in the attach window.
- Sync calls were not material: 432 `fsync` calls and 1 `msync` call totaled about 66 ms, with the slowest about 10 ms.

### The slow path is in import/finalization

macOS `sample` snapshots repeatedly show the final `lean` process inside:

```text
Lean_importModules
Lean_finalizeImport
```

The process opens/maps about 10,000 file entries, including thousands of `.olean`, `.olean.*`, and `.ir` files. `vmmap` saw about 7.4 GB of mapped files across roughly 42k regions.

### Prewarm and RAM disk did not make macOS Linux-fast

Cache/prewarm experiments:

```text
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27820837960
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27821727814
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27822430217
```

showed:

- Ubuntu warm import stays around 5-6 seconds.
- Linux after `drop_caches` rises to 27-34 seconds, and explicit prewarm restores 5-6 seconds.
- macOS stays slow across repeated warm runs and after explicit prewarm of the same `.olean*`/`.ir` artifacts.
- Running from a 9 GiB APFS RAM disk still took about 196 seconds, with no block input operations.

### Version curve

Version/import curve runs:

```text
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27823586757
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27824550417
```

showed the problem at least back to Lean/mathlib `v4.27.0`:

| Lean/mathlib | Ubuntu full `import Mathlib` | macOS full `import Mathlib` |
| --- | ---: | ---: |
| `v4.27.0` | 5.18s | 117.88s |
| `v4.30.0` | about 5s | about 118-172s |
| `v4.31.0` | about 5s | about 124-190s |

Current `mathlib-master` with Lean `4.32.0-rc1` was still around 114-122 seconds on macOS in these runs.

### Prefix bisection

Prefix bisection run:

```text
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27825733871
```

found that:

- Ubuntu full prefix, equivalent to `import Mathlib`, took 3.92 seconds.
- macOS 15.7.7 full prefix took 120.00 seconds.
- macOS 26.4 full prefix took 128.53 seconds.
- The estimated 60 second crossing point varied between macOS runners, suggesting broad cumulative scaling rather than one stable culprit import.

### Synthetic C repro/control

The repository includes `scripts/mmap-pattern-probe.c` and `.github/workflows/mmap-pattern-synthetic.yml`.

The synthetic fixture defaults are sized around the observed Lean footprint:

```text
20,000 files
192 KiB per file
2 mappings per file
40,000 total mappings
about 3.75 GB unique file bytes
about 7.5 GB mapped bytes
1 GiB resident anonymous heap for the import-like walk
```

Simple one-pass page-touch controls showed macOS is slower, but not enough to explain Lean by itself:

```text
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27876818772
```

Full 20,000-file permuted page-touch:

| OS | Time |
| --- | ---: |
| Ubuntu | 0.73s |
| macOS 15.7.7 | 15.12s |
| macOS 26.4 | 14.47s |

An import-like synthetic walk, which repeatedly revisits mapped files while keeping a heap resident, gets much closer:

```text
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27877479705
https://github.com/ejgallego/autoformalization-antigravity/actions/runs/27877552667
```

8-round permuted walk:

| OS | Time |
| --- | ---: |
| Ubuntu | 0.68s |
| macOS 15.7.7 | 35.61s |
| macOS 26.4 | 35.34s |

24-round permuted walk:

| OS | Time |
| --- | ---: |
| Ubuntu | 1.21s |
| macOS 15.7.7 | 74.71s |
| macOS 26.4 | 84.14s |

This synthetic test is not an `.olean` parser, but it supports the hypothesis that repeated non-sequential mmap-backed access plus resident heap pressure is enough to create a very large macOS/Linux split with no block input.

## Current Interpretation

The issue appears to be an interaction between Lean's full import/finalization access pattern and macOS VM/file-backed mmap behavior.

Evidence against other explanations:

- Not a Blueprint-specific issue: the minimal `import Mathlib` repro is enough.
- Not a Lake build-cache issue: timings are after `lake exe cache get` and `lake build Mathlib`.
- Not extra syscall count: Linux and macOS open/read/map the same order of artifacts.
- Not sync calls: sync time is negligible.
- Not physical disk I/O: macOS reports zero block input, and RAM disk/prewarm did not fix it.
- Not fixed by macOS 26 or newer Lean release candidates in the tested range.

Working hypothesis:

Lean finalizes a large import closure by walking many file-backed mapped `.olean`/`.ir` artifacts and persistent environment extension data while constructing/retaining a large in-memory object graph. On macOS hosted runners, this causes repeated file-backed page reactivation/page-in/reclaim behavior. Linux keeps the same workload effectively hot-cache and runs mostly CPU-bound.

## Possible Upstream Investigation Directions

- Inspect `Lean_importModules` / `Lean_finalizeImport`, especially persistent environment extension finalization, for repeated scattered passes over mapped module data.
- Look for opportunities to improve locality: batch extension finalization, reduce revisits to older mapped data, or process imported module payloads in a more sequential order.
- Revisit whether module data can be cached or shared across duplicate loads. This may be adjacent to `leanprover/lean4#3826` (`importModules{WithCache}` / `ModuleData` caching), though this repro is a single-process CLI import.
- Consider whether macOS-specific mmap hints could help. Simple explicit file prewarm did not help, so any fix probably needs to match the actual mapped access pattern rather than just reading every artifact once.
- Consider reducing the number or total size of file-backed mappings, or changing artifact layout to improve locality for full-umbrella imports.
- Compare with a high-memory/self-hosted macOS runner to separate "macOS VM behavior in general" from "GitHub-hosted Apple M1 virtual runner memory pressure".

## Workarounds For Affected Projects

- Avoid bare `import Mathlib` in runtime/executable paths on macOS CI.
- Use narrower imports where possible.
- For unavoidable full-Mathlib import tests on macOS CI, use a high timeout or a higher-memory/self-hosted macOS runner.
- Prefer checking this path on Linux CI unless macOS-specific behavior is what is being tested.

## Suggested Upstream Ask

Could Lean maintainers advise whether the current import/finalization implementation has known repeated mmap-backed access patterns that would explain this, and whether there are existing plans or experimental branches around module-data caching, persistent-extension finalization locality, or macOS-specific module loading behavior?
