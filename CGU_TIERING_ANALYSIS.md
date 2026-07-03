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

Benchmark: `cargo build --release -j1` of serde\_json + benchtool (3 runs)

| Configuration | Time | vs default | vs stock |
|-------------|------|-----------|----------|
| Stock 1.96.1 | 14.1s | — | — |
| Our stage2 (no flags) | 11.4s | — | -19% |
| Stage2 + fn-opt-levels | 10.2s | **-10%** | **-28%** |

The per-function optimization (`fn-opt-levels`) adds a clear ~10% improvement over the baseline stage2. Cold functions in hot CGUs get size-reducing LLVM attrs, reducing code bloat and improving I-cache.

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
