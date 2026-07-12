# Shrinking the Rust Toolchain

Analysis of what occupies ~1.5 GB in the stock `1.96.1-x86_64-unknown-linux-gnu`
toolchain, what can be trimmed, and how the `sizewalk.sh` configurations map to
real space savings.

## 1.  Size Breakdown

Path                                                         Size    Nature
------------------------------------------------------------ ------- --------------------------------
`share/doc/rust/html/`                                       785 MB  Rustdoc HTML (core, std, alloc,
                                                                     reference, book, by-example, …)
`lib/libLLVM.so.22.1-rust-1.96.1-stable`                     191 MB  Prebuilt LLVM — **not stripped**
`lib/librustc_driver-*.so`                                   145 MB  The compiler — **not stripped**,
                                                                     lto=fat cgu=1 O3
`lib/rustlib/x86_64-unknown-linux-gnu/lib/*.rmeta`           101 MB  LLVM bitcode metadata for LTO
                                                                     (libcore.rmeta alone = 61 MB)
`lib/rustlib/src/rust/`                                       53 MB  Rust stdlib source (needed for
                                                                     `-Z build-std`; optional for
                                                                     normal compilation)
`bin/cargo`                                                    41 MB  **not stripped**
`lib/rustlib/x86_64-unknown-linux-gnu/lib/*.rlib`             33 MB  Static archive libraries
`bin/clippy-driver`                                            20 MB  **not stripped**
`lib/rustlib/x86_64-unknown-linux-gnu/lib/*.a` (sanitizers)   20 MB  asan, tsan, msan, lsan, dfsan, rtsan
`lib/rustlib/x86_64-unknown-linux-gnu/bin/` (lld …)           17 MB  **not stripped**
`bin/rustdoc`                                                  13 MB  **not stripped**
`bin/rustfmt, bin/cargo-fmt`                                   ~9 MB  **not stripped**
`lib/rustlib/x86_64-unknown-linux-gnu/lib/libstd*.so`        5.2 MB  Dynamic libstd (shipped but unused
                                                                     by compiler tools)
others                                                         ~9 MB  man pages, shell completions, etc.
------------------------------------------------------------ ------- --------------------------------
**Total**                                                    ~1500 MB

## 2.  What Can Be Shrunk — and By How Much

### 2.1  Remove components entirely (zero build cost)

| Component | Command | Saving |
|---|---|---|
| HTML docs | `rustup component remove rust-docs` | **−785 MB** |
| Source code | `rustup component remove rust-src` | **−53 MB** |
| **Total removable** | | **−838 MB** |

The HTML docs are more than half the toolchain.  They are helpful for offline
browsing but completely unnecessary for compilation.

### 2.2  Strip debug symbols (no rebuild, just post-process)

Every shipped ELF binary is **not stripped**.  The stock upstream intentionally
distributes them with full debug info so that LLVM/rustc ICE reports produce
meaningful backtraces.  For deployment or embedded scenarios you can reclaim
a lot of space:

| Binary | Current | `strip --strip-debug` est. | Saving |
|---|---|---|---|
| `libLLVM.so.22.1` (C++ — large debug info) | 191 MB | ~100 MB | **~90 MB** |
| `librustc_driver.so` | 145 MB | ~90 MB | **~55 MB** |
| `bin/cargo` | 41 MB | ~25 MB | **~16 MB** |
| `bin/clippy-driver` | 20 MB | ~12 MB | **~8 MB** |
| `bin/rustdoc` | 13 MB | ~8 MB | **~5 MB** |
| `lib/rustlib/x86_64/bin/*` (lld etc.) | 17 MB | ~10 MB | **~7 MB** |
| `bin/rustfmt`, `bin/cargo-fmt` | ~9 MB | ~5 MB | **~4 MB** |
| Sanitizer `.a` archives | 20 MB | ~12 MB | **~8 MB** |
| `libstd.so` | 5.2 MB | ~3 MB | **~2 MB** |
| **Total strip** | | | **~195 MB** |

### 2.3  Rebuild with size-conscious compile flags

These require recompiling the compiler or stdlib.  The `sizewalk.sh` script
quantifies the most important one — `librustc_driver.so`.

| Change | librustc_driver.so est. | Saving vs stock |
|---|---|---|
| Stock (lto=fat, cgu=1, O3, not stripped) | 145 MB | — |
| `strip --strip-debug` only | ~90 MB | −55 MB |
| `-C opt-level=z` + lto=fat (no strip) | ~115 MB | −30 MB |
| `-C opt-level=z` + strip | ~70 MB | −75 MB |
| PGSO (cgu + fn) + strip | ~70–85 MB | −60–75 MB |
| Brute-opt-quick + strip | ~65–80 MB | −65–80 MB |

The `.rmeta` files (101 MB, especially libcore's 61 MB) are LLVM bitcode
metadata.  They are required for LTO and cannot be stripped.  Rebuilding stdlib
with `-C opt-level=z` may shrink them by 10–20 MB.

### 2.4  Aggregate potential

```
Starting point:            ~1500 MB
──────────────────────────────────────────────
Remove docs + src:          −838 MB  →  662 MB
Strip all ELF:              −195 MB  →  467 MB
Recompile rustc with PGSO:  − 30 MB  →  437 MB
Recompile stdlib with -Oz:  − 15 MB  →  422 MB
──────────────────────────────────────────────
Aggressive total:          −1078 MB  →  422 MB
```

A "minimal working compiler" that can rebuild itself fits in roughly **350–450 MB**.

## 3.  Could We Link Dynamically Against libstd?

### 3.1  Current linkage

```
$ readelf -d librustc_driver.so | grep NEEDED
  libdl.so.2
  libLLVM.so.22.1-rust-1.96.1-stable
  libgcc_s.so.1
  librt.so.1
  libpthread.so.0
  libc.so.6
  ld-linux-x86-64.so.2
```

**libstd.so is not in NEEDED.**  Every Rust binary (rustc_driver, cargo,
clippy-driver, rustdoc, rustfmt) statically links its own copy of libstd.

A dynamic `libstd.so` (5.2 MB) **is** shipped in `lib/rustlib/…/lib/` for the
benefit of user programs that request `#[cfg(target_feature = "crt-static")]`,
but the compiler tools don't use it.

### 3.2  The build-system machinery

The bootstrap code already has full support for `-Cprefer-dynamic`:

**`src/bootstrap/src/core/builder/cargo.rs`**:
```rust
// libstd gets built as a dylib
if matches!(mode, Mode::Std) {
    rustflags.arg("-Cprefer-dynamic");
}
// rustc_driver does NOT get prefer-dynamic on Linux
if matches!(mode, Mode::Rustc) && !self.link_std_into_rustc_driver(target) {
    rustflags.arg("-Cprefer-dynamic");
}
```

**`src/bootstrap/src/core/builder/mod.rs`**:
```rust
pub fn link_std_into_rustc_driver(&self, target: TargetSelection) -> bool {
    !target.triple.ends_with("-windows-gnu")   // true on Linux
}
```

**`src/bootstrap/src/bin/rustc.rs`** — the rustc shim strips any residual
`-Cprefer-dynamic` when the env var says so:
```rust
if env::var("RUSTC_LINK_STD_INTO_RUSTC_DRIVER") == "1"
    && crate_name == Some("rustc_driver")
{
    // remove -Cprefer-dynamic from args
}
```

### 3.3  What it would take

You cannot simply set `RUSTC_LINK_STD_INTO_RUSTC_DRIVER=0` in the environment —
`cargo.env()` in the bootstrap code overrides it back to `"1"`.  The change
requires a one-line fork edit:

```diff
- !target.triple.ends_with("-windows-gnu")
+ false
```

Then every Rust binary produced by that fork would dynamically link `libstd.so`,
which must be findable via `LD_LIBRARY_PATH` or rpath at runtime.

### 3.4  Why it's not done

| Reason | Detail |
|---|---|
| **Performance** | Dynamic linking adds PLT/GOT indirection on every cross-crate call. For the compiler hot path this is measurable. |
| **Reliability** | The compiler must start even when `LD_LIBRARY_PATH` is misconfigured. An ICE caused by a missing `.so` is worse than a compile error. |
| **LTO boundary** | Static linking lets LLVM inline across the libstd boundary. With a `.so` the boundary is frozen, losing optimization opportunities. |
| **Diminishing returns** | libstd.rlib is 12 MB but only the functions actually used by the binary survive LTO + GC. The net saving is ~2–7 MB per binary, not the full 12 MB. |

### 3.5  Practical saving comparison

```
Action                            Saving   Effort
──────────────────────────────────────────────────────
strip --strip-debug on LLVM        ~90 MB  trivial (post-build)
strip --strip-debug on tools      ~105 MB  trivial (post-build)
Remove rust-docs                  785 MB  trivial (rustup component)
Dynamic-link libstd                 ~7 MB  nontrivial (fork bootstrap)
```

**Stripping debug symbols yields ~200 MB for zero build time.**  Dynamic-linking
libstd yields ~7 MB and requires a fork.  The sizewalk project focuses on the
bigger lever: compile-time flags for `librustc_driver.so` (20–75 MB saving)
combined with post-build stripping (55 MB).

## 4.  Connection to sizewalk.sh

The `scripts/sizewalk.sh` script measures the biggest piece we control:
**`librustc_driver.so` size** across six build configurations.

```
Step  Config                              Driver    Stripped  Estimate vs stock
                                          (MB)      (MB)      (stock = 145 unstripped)
────  ──────────────────────────────      ──────    ────────  ─────────────────────
  1   Default (stock Cargo, no size        ~200?     ~130?    baseline with no LTO
      opts — .cargo/config.toml disabled)
  2   Standard size opts (lto=fat,         ~145      ~90      matches stock
      cgu=1 — config.toml active)
  2.5 Stripped standard size opts          (145)     ~90      isolated strip saving
                                                                   (step 2 + strip)
  3   CGU-PGSO only                                    ~85?    CGU overrides alone
  4   CGU + fn PGSO                                    ~80?    combined PGSO
  5   Brute-opt-quick refined                          ~75?    optimised CGU levels
  6   Fn-only PGSO (no CGU)                            ~85?    fn overrides alone
```

The "Stripped" column shows what each configuration would measure after
`strip --strip-debug` (the script logs both columns automatically).

### What the numbers mean

- **Step 1** vs **Step 2** = the cost of LTO (lto=fat makes the binary larger
  because more inlining happens, but it's faster).
- **Step 2** vs **Step 2.5** = the pure debug-info tax (~55 MB).
- **Step 2** vs **Steps 3–6** = the PGSO savings on top of the standard config.
- **Step 2.5 stripped** vs **Step 4/5 stripped** = the total saving from PGSO
  *plus* stripping, relative to the stock toolchain.

### The 350 MB floor

Even with all optimisations, the essential compiler consists of:

```
librustc_driver.so  (~70 MB stripped, PGSO-optimised)
libLLVM.so          (~100 MB stripped, prebuilt)
lib/rustlib/        (~100 MB rmeta + rlib, necessary for compilation)
cargo               (~25 MB stripped)
Various helpers     (~50 MB stripped)
────────────────
~345 MB
```

This is the practical lower bound for a working, self-hosting compiler.

## 5.  Could We Merge Everything Into a Busybox-Style Single Binary?

### 5.1  What already shares code

The tools already share `librustc_driver.so` at runtime:

```
Tool              Size   Links against          Standalone parts
──────────────────────────────────────────────────────────────────
clippy-driver     20 MB  librustc_driver.so     thin wrapper
rustdoc           13 MB  librustc_driver.so     thin wrapper
rustfmt            5 MB  librustc_driver.so     thin wrapper
cargo-clippy       1 MB  librustc_driver.so     thin wrapper
cargo             41 MB  — (nothing)            fully independent
cargo-fmt          4 MB  — (nothing)            fully independent
rust-lld          12 MB  libLLVM.so             fully independent
wasm-component-ld  5 MB  libLLVM.so             fully independent
rust-objcopy     275 KB  libLLVM.so             fully independent
```

The four driver-using tools already get the compiler code (145 MB) from a
shared `.so`.  What they duplicate is:

- **libstd** (~7 MB each, statically linked inside each binary).  `librustc_driver`
  has its own private copy of libstd, and rustdoc/rustfmt/clippy each have
  another.  None of them export `std::` symbols, so the dynamic linker can't
  deduplicate.
- **ELF overhead** (~1 MB per binary for headers, PLT, section tables).
- **Per-tool unique logic** (small — each tool is mostly compiler library calls).

### 5.2  What a busybox would save

| Duplication source | Per-tool | Affected tools | Saving |
|---|---|---|---|
| Duplicated libstd | ~7 MB | 4 driver-using tools | ~28 MB |
| ELF overhead | ~1 MB | 6+ binaries | ~6 MB |
| cargo merged (no longer standalone) | — | 1 | ~20 MB\* |
| **Total busybox saving** | | | **~54 MB** |

\*cargo's unique code doesn't disappear — it's still in the combined binary.
The 20 MB is the overhead of being a separate binary (libstd + ELH headers).

For context, that's **54 MB** from a major refactor vs **195 MB** from a
one-liner `strip` command and **838 MB** from `rustup component remove`.

### 5.3  The structural problem

The toolchain is three independent codebases:

| Component | Source | Deps | Entry point |
|---|---|---|---|
| `compiler/rustc` | `librustc_driver` crate | compiler deps only | `rustc_driver::main()` |
| `src/tools/cargo/` | separate Cargo.toml | git2, curl, serde, … | `cargo::main()` |
| `src/tools/clippy/` | separate Cargo.toml | `rustc_driver` as lib | `clippy_driver::main()` |
| `src/tools/rustfmt/` | separate Cargo.toml | `rustc_driver` as lib | `rustfmt::main()` |

To combine them into one binary you need one of two strategies:

#### Strategy A: Multi-call binary (busybox style)

Install symlinks so that `cargo`, `clippy-driver`, `rustfmt`, `rustdoc` all
point to the same ELF.  The binary inspects `argv[0]` and dispatches:

```rust
fn main() {
    let tool = std::path::Path::new(&std::env::args().next().unwrap())
        .file_stem().unwrap().to_str().unwrap();
    match tool {
        "rustc"         => rustc_driver::main(),
        "cargo"         => cargo::main(),
        "clippy-driver" => clippy_driver::main(),
        "rustfmt"       => rustfmt::main(),
        "rustdoc"       => rustdoc::main(),
        _               => { eprintln!("unknown tool: {tool}"); std::process::exit(1); }
    }
}
```

This works because the symlink preserves `argv[0]`.  The practical costs:

- **Every tool loads every other tool's code** into RSS.  Running `cargo build`
  maps the clippy, rustfmt and rustdoc code into memory even though it's never
  called.  For a 200 MB binary that's a real hit.
- **Every rebuild recompiles the entire toolbox.**
- **cargo's dependency tree** (git2, libssh2, libgit2, curl, …) gets linked into
  every invocation, even `rustc foo.rs`.

#### Strategy B: Subcommand dispatch (`rustc toolbox cargo build`)

Each tool exposes its entry point as a library function, and `rustc` itself
(or a new `rustc-toolbox` binary) dispatches:

```
rustc clippy foo.rs      # runs clippy
rustc fmt --check        # runs rustfmt
rustc doc --open         # runs rustdoc
```

This avoids the argv[0] symlink trick but requires:

1. Each tool to be refactored so its CLI parsing is a library call, not `main()`.
2. `rustc` to grow subcommand routing.
3. Upstream consensus — which doesn't exist (tool maintainers prefer independent
   binaries for faster iteration).

### 5.4  Has anyone done this?

| Project | Approach | Why it works |
|---|---|---|
| **Busybox** | Multi-call for coreutils | Each tool is a single C file; combined 2 MB |
| **toybox** | Same, Android | Same — each tool is trivial |
| **rust-analyzer** | Single binary with subcommands | Single project from day one |
| **llvm-tools** (our `rust-lld`) | Separate binaries | Each links libLLVM only; no shared rustc |

`rust-analyzer` is the closest analogy — it ships one binary with subcommands
(`rust-analyzer`, `rust-analyzer proc-macro-server`, etc.).  But it was
designed that way from the start, not a retrofit of six independent projects.

### 5.5  Bottom line

```
Action                            Saving   Effort
──────────────────────────────────────────────────────
Remove docs + src                 838 MB   trivial
strip --strip-debug all ELF       195 MB   trivial
PGSO + strip on rustc_driver       75 MB   build-time (automated in sizewalk)
Busybox single binary              54 MB   major fork + ongoing maintenance
```

The tools already share `librustc_driver.so`.  A busybox would save the
remaining per-tool overhead — mainly duplicated libstd — but at the cost of
higher RSS per invocation, longer rebuilds, and a fork that diverges from
upstream.


## 6.  Quick-Reference Commands

```bash
# Remove documentation and source (safest first step)
rustup component remove rust-docs rust-src

# Strip all ELF binaries in the toolchain
TOOLCHAIN_DIR=$(rustc --print sysroot)
find "$TOOLCHAIN_DIR/lib"     -name '*.so' ! -name '*.so.*' -exec strip --strip-debug {} \;
find "$TOOLCHAIN_DIR/lib"     -name '*.so.*'                -exec strip --strip-debug {} \;
find "$TOOLCHAIN_DIR/bin"     -type f -executable           -exec strip --strip-debug {} \;
find "$TOOLCHAIN_DIR/libexec" -type f -executable           -exec strip --strip-debug {} \;

# Or with our stage2 build (runs all 6 configs + stripping):
./scripts/sizewalk.sh
```

## 7.  Files Referenced

| File | Purpose |
|---|---|
| `scripts/sizewalk.sh` | Builds and measures rustc_driver across 6 configs with strip tracking |
| `build/pgo_data/cgu_opt_levels_1x.txt` | Standard PGSO per-CGU optimisation levels |
| `build/pgo_data/fn_opt_levels_1x.txt` | Standard PGSO per-function optimisation levels |
| `build/pgo_data/cgu_opt_levels_brute_quick.txt` | Brute-force optimised CGU levels |
| `config.toml` | `lto="fat"`, `codegen-units=1` — our standard size options |
| `src/bootstrap/src/core/builder/cargo.rs` | Bootstrap logic for `-Cprefer-dynamic` |
| `src/bootstrap/src/core/builder/mod.rs` | `link_std_into_rustc_driver()` decision |
| `src/bootstrap/src/bin/rustc.rs` | Rustc shim that strips `-Cprefer-dynamic` |
