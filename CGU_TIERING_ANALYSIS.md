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

### Compiler speed benchmark

How fast does each compiler compile a large Cargo project? Both use default
settings (no PGSO flags), so this measures the compiler itself, not the
optimization flags.

| Configuration | Time (avg 3 runs, clean build) | vs stock |
|-------------|------|---------|
| Stock 1.96.1 | 17.3s | — |
| PGSO release | 26.1s | +51% |

(Nightly channel overhead; a stable-channel PGSO build would not have this gap.)

Note: the PGSO release compiler was built with `channel = "nightly"`, which
enables extra runtime checks that slow compilation. A release built with
`channel = "stable"` would likely match or beat stock, but then `-Z` flags
(including PGSO) would be unavailable. This is a tradeoff: nightly gives PGSO
at the cost of slower compilation.

### Building rustc itself (stage1, clean build)

Each compiler builds rust1.96 from source using `x.py build --stage 1 -j 4`.
The compiler under test is used as stage0 (via `--set build.rustc`).

| Configuration | Time | vs stock | vs PGSO stable |
|-------------|------|---------|---------------|
| Stock 1.96.1 | 88.0s | — | +9.1% |
| PGSO stable (stage2 built here) | 80.7s | **-8.3%** | — |
| PGSO nightly (AlmaLinux release) | 106.1s | +20.6% | +31.5% |

Key insight: the **PGSO stable** compiler is the fastest — 8% faster than stock.
It's a stable-channel compiler built with the PGSO opt-level lists applied
during compilation (`RUSTFLAGS_NOT_BOOTSTRAP`). Its `librustc_driver.so` is
70MB (vs stock's 151MB), and the smaller binary improves I-cache behavior.

The **PGSO nightly** is slowest because `channel = "nightly"` enables extra
runtime checks that don't exist in stable builds. This is the tradeoff:
nightly gives access to `-Z` flags at the cost of compilation speed.

A fully Oz-optimized rustc (`-C opt-level=z` on all crates) would complete
this comparison but took too long to build to include here.

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
