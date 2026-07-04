# rustc PGSO (Profile Guided Size Optimisation) Fork

Fork of Rust with file-driven CGU tiering and per-function optimization levels.
Generally there is much more cold code than hot code and hot code dominates speed.
It may result in roughly halving your binary size without affecting speed much.

## Quick start (one-liner — profiles your project)
```bash
curl -sL https://github.com/gmatht/rust/raw/stable-pgso/optimize-project.sh | bash -s -- --train-cmd 'YOUR_BENCHMARK --YOUR_OPTIONS'
```

This profiles your project with PGO, generates opt-level lists, then rebuilds
with PGSO applied. The resulting binary has hot code optimized for speed and
cold code optimized for size.

## Caveats
- This is my first attempt at modifying rust. I may have broken something important
- This is just a prototype
    - I have made no effort to make this code maintainable or conformant to rust coding guidlines.
    - Don't submit a pull request to upstream Rust!
I am not sure this is even needed any more. Splitting CGUs is generally bad for size
Spliting the CGUs into hot and cold seems to balance out and only give trivial size performance gains.
So, we tend to only have one CGU per crate and per-CGU optimisation levels become just per crate
optimisation levels. And per crate optimisation levels can already be done with Cargo?
And upstream seems to already have some kind of per-function optimisation level? 


## Purpose
The purpose of this is to make hot code fast and cold code small in rust projects.
- without hand-editing component crates
- Keep the hot/warm/tepid/cold code heuristics flexible by using externally supplied lists
  - And provide scripts so they don't need to be created by hand.

## Design
- `-Z cgu-opt-levels=<path>` controls CGU-level optimization.
- `-Z fn-opt-levels=<path>` controls per-function LLVM attributes.
- `-Z hot-cold-split` remains enabled for size reduction.
- `src/tools/generate_opt_levels.py` generates the optimization maps from PGO counts.
- `optimize-rustc.sh` is the rustc-specific train -> merge -> regenerate -> rebuild flow.
- `optimize-project.sh` captures PGO for a generic Cargo/Rust project.

## Usage
### Build the optimized rustc compiler locally
```bash
./optimize-rustc.sh \
  --workdir /path/to/project \
  --train-cmd 'cargo build --release'
```

### Rebuild rustc with the saved lists
```bash
RUSTFLAGS_NOT_BOOTSTRAP="-Z hot-cold-split \
  -Z cgu-opt-levels=build/pgo_data/cgu_opt_levels.txt \
  -Z fn-opt-levels=build/pgo_data/fn_opt_levels.txt" \
python3 x.py build --stage 2 compiler/rustc library/std
```
### Build the current directory with PGSO
```bash
cd /path/to/project
../rustc/optimize-project.sh --train-cmd 'YOUR_BENCHMARK --YOUR_OPTIONS'
```

### Use the PGSO compiler for your own project
```bash
./optimize-project.sh --train-cmd 'YOUR_BENCHMARK --YOUR_OPTIONS'
```

### Build Linux and Win64 binaries
```bash
./build-linux-win64.sh
```
Windows toolchain overrides if needed:
```bash
WINDOWS_CARGO=/mnt/c/Users/s_pam/.cargo/bin/cargo.exe \
WINDOWS_RUSTC=/mnt/c/Users/s_pam/.cargo/bin/rustc.exe \
WINDOWS_BUILD_DIR=/mnt/d/tmp/rust-pgso-win64-build \
./build-linux-win64.sh
```

### Build on AlmaLinux 8 (GLIBC 2.28, wide Linux compatibility)
```bash
./build-in-centos7.sh  # works on AlmaLinux 8 WSL
```

### Release workflow
- `.github/workflows/optimized-rustc-release.yml`

## Benchmarks
I haven't made much effort to make the benchmarks accurate yet, but they *might* give a rough guide.

See [CGU\_TIERING\_ANALYSIS.md](CGU_TIERING_ANALYSIS.md) for:
- binary size comparison
- serde\_json + benchtool timing results
- stock 1.96.1 stdlib compatibility notes

## Docs
- [CGU\_TIERING\_ANALYSIS.md](CGU_TIERING_ANALYSIS.md)
- [GENERIC\_PGO\_WRAPPER\_PLAN.md](GENERIC_PGO_WRAPPER_PLAN.md)
- [optimize-project.sh](optimize-project.sh) — unified wrapper (auto-installs toolchain, profiles, builds)
- [optimize-rustc.sh](optimize-rustc.sh) — rustc-specific train/rebuild flow
