# PGSO (Profile-Guided Size Optimization) in Rust

## Overview

PGSO uses PGO profile data to identify cold functions and apply size optimization attributes (`optsize`/`minsize`) to them, while keeping hot functions at the full optimization level. This aims to replicate the effect of manually splitting hot code into a separate crate compiled at high optimization (split-lib), but automatically via profiling.

## Flag

```
-C pgo-cold-func-opt={default|optsize|minsize|optnone}
```

Applied in `RUSTFLAGS` alongside `-C profile-use=<profdata>`.

## Implementation Status

- Implemented in: rustc stage1 (LLVM 22.1.7)
- Not yet in: nightly (LLVM 21.1.1)
- PR not yet submitted to rust-lang/rust

## Benchmark: prime-finder

Single-crate prime sieve benchmark. Hot code: `is_prime()` in a tight loop for 3s. Cold code: clap arg parsing, num-bigint printing, program setup.

### Baseline (no PGO, no PGSO)

All numbers from stage1 (LLVM 22) unless noted. `iters` = loop iterations completed in 3s (higher is better).

| Config | Size | Iters (3s) | vs Oz-LTO size |
|--------|------|------------|----------------|
| Oz | 952,744 | 254M | — |
| Os | 957,704 | 252M | — |
| O2 | 1,039,352 | 352M | — |
| O3 | 1,039,832 | 357M | — |
| **Oz-LTO** | **902,640** | **261M** | baseline |
| Os-LTO | 901,168 | 261M | -1,472 |
| O2-LTO | 1,040,112 | 354M | +137,472 |
| O3-LTO | 1,033,120 | 364M | +130,480 |

Nightly (LLVM 21) for reference:
| Config | Size | Iters |
|--------|------|-------|
| Oz-LTO (nightly) | **793,408** | — |
| O3-LTO (nightly) | **910,824** | — |

**Stage1 produces ~110KB larger binaries than nightly** due to LLVM 22 vs LLVM 21 codegen differences.

### PGO only

Profile: instrumented binary runs for 3s, raw profiles merged via `llvm-profdata merge`.

| Config | Size | Iters | vs no-PGO |
|--------|------|-------|-----------|
| Oz-PGO | 953,224 | 299M | +45M vs Oz |
| Os-PGO | 973,640 | 260M | +8M vs Os |
| O2-PGO | 1,024,056 | 360M | +8M vs O2 |
| O3-PGO | 1,037,464 | 349M | -8M vs O3 |
| **Oz-PGO-LTO** | **902,960** | **253M** | -8M vs Oz-LTO |
| Os-PGO-LTO | 912,288 | 288M | +27M vs Os-LTO |
| O2-PGO-LTO | 1,012,320 | 359M | +5M vs O2-LTO |

PGO helps Oz the most (+45M iterations) by identifying hot code even at size-optimization levels. PGO+LTO gives mixed results — sometimes worse than PGO alone.

### PGSO: `-C pgo-cold-func-opt=optsize`

| Config | Size | Iters | vs PGO-LTO size |
|--------|------|-------|-----------------|
| Oz-PGO-optsize | 953,224 | 312M | same (no LTO) |
| Os-PGO-optsize | 973,640 | 256M | same (no LTO) |
| O2-PGO-optsize | 1,024,184 | 363M | same (no LTO) |
| O3-PGO-optsize | 1,037,720 | 372M | same (no LTO) |
| **Oz-PGO-LTO-optsize** | **901,568** | **248M** | **-1,392** |
| Os-PGO-LTO-optsize | 910,912 | 246M | -1,376 |
| O2-PGO-LTO-optsize | 1,010,080 | 355M | -2,240 |
| O3-PGO-LTO-optsize | 1,032,832 | 362M | -288 |

**Without LTO**: no measurable effect — `optsize` attribute needs whole-program view.  
**With LTO**: consistent 1-2KB savings, identical performance. Correct but modest.

### PGSO: `-C pgo-cold-func-opt=minsize`

| Config | Size | Iters | vs PGO-LTO size |
|--------|------|-------|-----------------|
| Oz-PGO-minsize | 953,224 | 300M | same (no LTO) |
| O2-PGO-minsize | 1,024,168 | 357M | same (no LTO) |
| O3-PGO-minsize | 1,037,704 | 353M | same (no LTO) |
| O2-PGO-LTO-minsize | 1,008,464 | 357M | **-3,856** |
| O3-PGO-LTO-minsize | 1,031,632 | 359M | -1,488 |

`minsize` saves slightly more than `optsize` with LTO, as expected.

### PGSO + LLVM `--force-pgso`

The `--force-pgso` LLVM flag (via `-C llvm-args=--force-pgso`) forces PGSO on functions with no profile data.

| Config | Size | Iters | vs PGO-LTO |
|--------|------|-------|------------|
| O2-PGO-LTO | 1,012,320 | 362M | baseline |
| O2-PGO-LTO-minsize | 1,008,464 | 368M | -3,856, same perf |
| O2-PGO-LTO-force-pgso | 979,280 | 240M | **-33,040, but 34% slower** |
| O2-PGO-LTO-minsize+force | 975,504 | 236M | -36,816, 35% slower |

**`--force-pgso` is destructive.** It applies size optimization to hot functions too, dropping performance to Oz levels. Not recommended.

### Split-lib (manual hot/cold split)

Binary crate at Oz, library crate (containing `is_prime`) at O2/O3.

| Config | Size | Iters |
|--------|------|-------|
| Oz-bin-O2-lib | 952,984 | 354M |
| **Oz-bin-O3-lib** | **953,000** | **358M** |
| Os-bin-O2-lib | 957,928 | 349M |
| Os-bin-O3-lib | 957,944 | 343M |
| **Oz-bin-O2-lib-LTO** | **902,784** | **350M** |
| Oz-bin-O3-lib-LTO | 902,784 | 329M |
| Os-bin-O2-lib-LTO | 901,408 | 352M |
| Os-bin-O3-lib-LTO | 901,408 | 351M |

Split-lib achieves better performance than PGO/PGSO in many cases. The cross-crate boundary prevents inlining of `is_prime`, but at O3 the function is fast enough to compensate. The cold code (binary crate at Oz) is significantly smaller than when compiled at O3.

## Key Findings

### 1. PGSO works, but effects are modest in small benchmarks

`-C pgo-cold-func-opt=optsize` / `minsize` correctly identifies cold functions via PGO and applies size attributes. Savings are 1-4KB in this benchmark because the cold code (clap, num-bigint) is already small when compiled at O2/O3.

### 2. `minsize` attribute ≠ Oz compilation

The `minsize` attribute on a function compiled at O3 does **not** produce the same code as compiling the function at Oz directly. It's a hint to the inliner/prefer-size heuristics, not a full opt-level switch. Functions tagged `minsize` at O3 still get O3-level register allocation, scheduling, etc.

For PGSO to match split-lib, cold functions would need to be compiled at a genuinely lower opt level (Oz) while hot functions stay at O3.

### 3. LTO is required for PGSO to have any effect

Without LTO, `optsize`/`minsize` attributes have no measurable effect on binary size. With LTO, savings are consistent but modest.

### 4. `--force-pgso` is counterproductive

This LLVM flag destroys hot-path performance by applying size optimization indiscriminately. Do not use.

### 5. Profile merging is critical

Raw `.profraw` files must be merged via `llvm-profdata merge` before use. Passing the directory to `-C profile-use` does **not** work (warning: "Is a directory"). The original benchmark script had this bug.

### 6. Split-lib still outperforms PGSO in this benchmark

For this specific benchmark, manual split-lib (Oz binary + O3 library + LTO) gives the best balance of size and speed. PGSO gets closer but doesn't match it because:

| Aspect | Split-lib | PGSO |
|--------|-----------|------|
| Hot code opt level | O3 | Same as base (O2/O3) |
| Cold code opt level | Oz | Same as base + `minsize` attribute |
| Cross-crate inlining | Prevented | Preserved (same crate) |
| Effort | Manual refactoring | Automatic via profiling |

### 7. LLVM IR analysis: how many functions get `cold`/`minsize`?

Analyzing the emitted LLVM IR from `O2-PGO-LTO-minsize` across **all 3771 function definitions** in the binary:

```
All crates combined:
  Total function definitions:  3771
  NOT cold:                    3174  (84.1%)  ← hot/warm functions
  Cold (any source):            597  (15.8%)
    ├─ cold + minsize (PGSO):   316  (8.3%)
    └─ cold only (static):      281  (7.5%)
```

Only **8.3%** of functions get `minsize` from PGSO. These are functions with near-zero PGO profile counts. Another **7.5%** are marked `cold` by LLVM's static analysis (panic handlers, abort paths, `noreturn` functions) but are **missed by PGSO** because it only considers PGO data, not static coldness.

The remaining **84.1%** of functions are "not cold" — they have profile counts > 0 from the 3-second profiling run (called at least once during startup), so PGSO considers them warm and doesn't touch them. **This is the core limitation**: PGSO's coldness threshold is too strict. Functions called once during program initialization are treated as warm, even though they're cold relative to the hot loop.

### 8. The reverse approach: Oz by default, O3 for hot functions

Current PGSO compiles everything at O2/O3 and adds `minsize` to cold functions. This doesn't work well because `minsize` at O3 ≠ Oz compilation.

**The reverse approach** would be: compile everything at Oz by default, then use PGO to identify hot functions and compile only those at O3 (via `#[optimize(speed)]` or similar). This would:

| Aspect | Current PGSO | Reverse (hot-func-opt) |
|--------|-------------|----------------------|
| Cold functions | O3 + `minsize` hint | Oz (truly small) |
| Hot functions | O3 (unchanged) | O3 via attribute |
| Savings | Tiny (1-4KB) | Large (approaches split-lib) |

This doesn't exist in LLVM today — `PGOOptions` only has `ColdFuncOpt`, no `HotFuncOpt`. It would require:

1. **LLVM change**: Add `PGOOptions::HotFuncOpt` to apply `#[optimize(speed)]` or similar to hot functions
2. **rustc change**: Wire up a `-C pgo-hot-func-opt={default|speed|O3}` option
3. The PGO pass would mark hot functions with the speed attribute, and a later pass could split them into separate codegen units at different opt levels

This is conceptually the correct approach and would match split-lib's behavior automatically. The current PGSO (`-C pgo-cold-func-opt`) is fundamentally limited because an attribute at O3 can't produce Oz-quality code — only a genuine opt-level change can.

## How to Use

```bash
# 1. Profile generation (needs nightly for profiler_builtins)
RUSTFLAGS="-C profile-generate=/tmp/pgo-out" cargo build --release
./target/release/myapp  # run to generate raw profiles

# 2. Merge raw profiles
llvm-profdata merge -o /tmp/pgo-out/merged.profdata /tmp/pgo-out/default_*.profraw

# 3. Profile use with PGSO (needs rustc with -C pgo-cold-func-opt)
RUSTFLAGS="-C profile-use=/tmp/pgo-out/merged.profdata -C pgo-cold-func-opt=minsize" \
  cargo build --release
```

For best results: **always use with LTO** (`profile.release.lto = "thin"`) and a higher opt level (`opt-level = 3`).
