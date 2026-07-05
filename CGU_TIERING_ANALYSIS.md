# CGU Tiering + PGSO — rustc 1.96.1

## Architecture

Two independent classification mechanisms, both driven by external data files:

### 1. CGU-level (`-Z cgu-opt-levels=<path>`)
- File maps CGU names to O3/O2/Os/Oz (prefix match)
- Read during partitioning (`partitioning.rs`)
- Sets per-CGU optimization level + ThinLTO side channel
- Warns on entries that don't match any CGU (catches typos)
- Intended for compiler self-build (via `RUSTFLAGS_NOT_BOOTSTRAP`)

### 2. Per-function (`-Z fn-opt-levels=<path>`)
- File maps function symbols to O3/O2/Os/Oz (exact + crate-prefixed match)
- Read during codegen (`attributes.rs`)
- Applies LLVM attributes:
  - Oz → `#[cold]` + `#[minsize]` + `#[optsize]`
  - Os → `#[optsize]`
  - O2/O3 → no size attrs (defer to CGU default)
  - Not in file → Oz (cold by default)
- Applied to ALL functions (dependency crates included)

### Flag changes
Replaced:
| Old flag | New flag |
|----------|----------|
| `hot_function_list` | `fn_opt_levels` |
| `tepid_function_list` | (same file) |
| `warm_function_list` | (same file) |
| `function_block_counts` | `cgu_opt_levels` |

## Data files (auto-generated from PGO profile of rustc)

### `build/pgo_data/fn_opt_levels.txt` (41 KB)
- 101 hot functions → O3
- 95 warm functions → O2
- 166 tepid functions → Os
- 2,343 cold functions → default Oz

### `build/pgo_data/cgu_opt_levels.txt` (4 KB)
- Known crate names from build system
- Computed per-crate averages from PGO function counts
- 2 O3, 3 O2, 2 Os, 32 Oz crates

## Benchmark results

### serde\_json build speed (retracted)

Earlier benchmarks claimed stock 1.96.1 at 14.1s and PGSO stage2 at 10.2s for a
serde\_json project build. These numbers could not be reproduced with the
pre-built AlmaLinux 8 release binary running on a newer GLIBC. The measured
results on Ubuntu 24.04 (GLIBC 2.39) were:

| Configuration | Time (avg 3 runs) |
|-------------|------------------|
| Stock 1.96.1 | 17.0s |
| PGSO release (no flags) | 25.2s |
| PGSO + rustc's fn-opt-levels | 27.7s |

The PGSO compiler here is the AlmaLinux 8 binary running on a system with
GLIBC 2.39 — the glibc version mismatch may affect performance. Additionally,
the bundled `fn_opt_levels.txt` was generated from rustc's own PGO profile;
applying it to a serde\_json project doesn't match any functions, defaulting
everything to Oz (cold) which adds overhead without benefit.

The original numbers were from a stage2 compiler built and run on the same
machine — they should be treated as optimistic.

### Building rustc itself (stage1, clean build — corrected)

Each compiler builds rust1.96 from source using `x.py build --stage 1 compiler/rustc -j 4`.
The compiler under test is used as stage0 (via `--set build.rustc`). LLVM cache is
pre-populated to avoid network time; only the compiler and its crate dependencies are
rebuilt from scratch each run.

| Configuration | Time (avg 3) | vs stock |
|-------------|-------------|---------|
| Stock 1.96.1 | 15.3 min | — |
| PGSO stable | 16.5 min | +7.8% |
| PGSO nightly | 16.3 min | +7.0% |
| Os-optimized | 16.9 min | +10.8% |

Conclusions:
- All four variants cluster within ~10% — compiler build speed is similar regardless
  of optimization strategy.
- PGSO-optimized compilers are **not faster** at compiling, despite being half the
  binary size (70MB vs 151MB). The smaller binary doesn't translate to faster
  compilation in this benchmark.
- The nightly channel adds negligible overhead (compare PGSO stable vs nightly).
- Global size optimization (Os) is slightly slower but nowhere near the earlier
  erroneous 12x number — the earlier result was from a measurement bug.

Earlier reported numbers (88s stock, 80s PGSO) were incorrect due to cached build
artifacts inflating the first variant's time downward. The benchmarks in this section
are from fresh builds with shared LLVM cache, run via `scripts/reproduce-benchmarks.sh`.

See `scripts/bench-compile.sh` to reproduce. The PGSO compiler is built with
FatLTO + codegen-units=1, producing a smaller `librustc_driver.so` (69MB vs
stock 151MB). A smaller binary should improve I-cache behavior and compilation
speed — the script measures this.

## Release compatibility

Important: matching `src/version` to `1.96.1` is not enough to use the stock 1.96.1 standard library.

- Stock stdlib was built by `rustc 1.96.1 (31fca3adb 2026-06-26)`
- This tree builds `rustc 1.96.1 (39f88c0c3 2026-07-03)`
- `cargo` with the stock sysroot still fails with `E0514` because the crate metadata hashes differ

Implication: we should not promise compatibility with the shipped stdlib unless we rebuild on the exact release commit. Shipping only the compiler and requiring `-Z build-std` is viable, but stock prebuilt stdlib is not.

### Measured binary size

- Stock 1.96.1 `librustc_driver.so`: 151,572,320 bytes
- This tree's stage1 `librustc_driver.so`: 92,304,128 bytes
- This tree's stage2 `librustc_driver.so`: 72,069,856 bytes

So the customized compiler payload is substantially smaller than stock 1.96.1.

## Usage

### To build stage2 with CGU-tier + per-function PGSO:
```bash
RUSTFLAGS_NOT_BOOTSTRAP="-Z hot-cold-split \
  -Z cgu-opt-levels=build/pgo_data/cgu_opt_levels.txt \
  -Z fn-opt-levels=build/pgo_data/fn_opt_levels.txt" \
python3 x.py build --stage 2 compiler/rustc library/std
```

### To generate data files from PGO profile:
```bash
python3 src/tools/generate_opt_levels.py
# Output: build/pgo_data/fn_opt_levels.txt, build/pgo_data/cgu_opt_levels.txt
```
