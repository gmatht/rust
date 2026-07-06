# rustc PGSO (Profile Guided Size Optimisation) Fork

Fork of Rust with file-driven CGU tiering and per-function optimization levels.
Generally there is much more cold code than hot code and hot code dominates speed.
It may result in roughly halving your binary size without affecting speed much.
In some cases I have seen it improve speed too (though some of my benchmarks seem
to give results that are too good to be true, I would take some of them with a grain
of salt, I'll need to double check that they are measuring what I think they are).

## Quick start (one-liner — profiles your project)
First you will need a project with some profdata. If you don't have one of your own
here is one I prepared earlier:

```bash
git clone https://github.com/gmatht/rust_pgo_Oz3_bench.git && cd rust_pgo_Oz3_bench
```

NOTE: While I don't think this the binary is infected with anything, and FWIW VirusTotal
reported no warnings. I STRONGLY RECOMMEND USING A CONTAINER/VM/JAIL ETC. IF YOU
ARE IN THE HABIT OF GRABBING RANDOM BINARIES OFF THE WEB. I am not publishing a Windows
binary, Windows users probably shouldn't trust random .exe files anyway.

Now that you have something to run PGSO on, you can use the one liner from your Linux container/VM: 

```bash
curl -sL https://github.com/gmatht/rust/raw/v1.96-pgso/optimize-project.sh | bash -s -- --profdata target/pgo-data-oz3/merged.profdata
```

Note that other projects are likely to put their profile data somewhere other than
'target/pgo-data-oz3/merged.profdata' so you may have to edit this argument.
They may even expect you to generate your own profile data.

### How `--train-cmd` works

The script sets `RUSTFLAGS=-Cprofile-generate=<dir>` in the environment before
running your command. Any `cargo build` inside your command inherits this flag,
producing an instrumented binary. Running that binary writes `.profraw` files
to the output directory.

**Important:** Your training command must respect `RUSTFLAGS` from the
environment. Tools that override `RUSTFLAGS` (e.g. `cargo pgo`) will break
instrumentation. The safe pattern is a plain `cargo build --release`.

After training, the script:
1. Merges `.profraw` into a `.profdata` profile
2. Extracts function hotness from the profile to generate opt-level lists
3. Rebuilds with `-Cprofile-use`, `-Z cgu-opt-levels`, `-Z fn-opt-levels`

## Caveats
- This is my first attempt at modifying rustc. I may have broken something important
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

### Rebuild with existing profile data (skip training)
```bash
./optimize-project.sh --profdata /path/to/merged.profdata
./optimize-rustc.sh --profdata /path/to/merged.profdata
```

### Rebuild rustc with the saved lists
```bash
RUSTFLAGS_NOT_BOOTSTRAP="-Z hot-cold-split \
  -Z cgu-opt-levels=target/pgo/cgu_opt_levels.txt \
  -Z fn-opt-levels=target/pgo/fn_opt_levels.txt" \
python3 x.py build --stage 2 compiler/rustc library/std
```
### Build the current directory with PGSO
```bash
cd /path/to/project
../rustc/optimize-project.sh --train-cmd 'cargo build --release && ./target/release/myapp'
```

### Use the PGSO compiler for your own project
```bash
./optimize-project.sh --train-cmd 'cargo build --release && ./target/release/myapp'
```

### Build Linux and Win64 binaries
```bash
./build-linux-win64.sh
```

### Build on AlmaLinux 8 (GLIBC 2.28, wide Linux compatibility)
```bash
./build-in-centos7.sh  # works on AlmaLinux 8 WSL
# Ironically doesn't work on centos7.
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
