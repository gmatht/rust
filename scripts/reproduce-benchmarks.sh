#!/usr/bin/env bash
# Reproduce the rustc build speed benchmark from CGU_TIERING_ANALYSIS.md.
# Builds each compiler variant from scratch, then times it building rustc.
#
# Expected run time: ~5-10 hours (each variant builds rustc in ~1-20 min,
# but building the variants themselves takes the bulk of the time).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOCK_TC="1.96.1"
RESULTS="/tmp/bench-results.txt"
RUNS=3
CACHE_DIR="/tmp/rustc-bench-cache"

echo "========================================================================="
echo "  Reproducing PGSO Compiler Benchmarks"
echo "========================================================================="
echo ""
echo "This script builds each compiler variant from source, then benchmarks"
echo "how fast each one builds rustc (stage1, clean build, -j 4)."
echo ""
echo "Variants:"
echo "  1. Stock 1.96.1 (from rustup)"
echo "  2. PGSO stable (built with RUSTFLAGS_NOT_BOOTSTRAP opt-level lists)"
echo "  3. PGSO nightly (built with channel=nightly for -Z flag access)"
echo "  4. Os-optimized (built with -C opt-level=s everywhere)"
echo ""

cd "$ROOT"

# ----- Helper functions -----

rustc_path() {
    local tc="$1"
    case "$tc" in
        stock)     rustup which rustc --toolchain "$STOCK_TC" 2>/dev/null ;;
        pgso-stable) echo "$ROOT/build-stage2-pgso-stable/x86_64-unknown-linux-gnu/stage2/bin/rustc" ;;
        pgso-nightly) echo "/tmp/pgso-pgso-almalinux8/bin/rustc" ;;
        os)        echo "$ROOT/build-stage2-os/x86_64-unknown-linux-gnu/stage2/bin/rustc" ;;
    esac
}

cargo_path() {
    # Always use stock cargo for building rustc itself.
    # The nightly cargo (1.98.0) is incompatible with the 1.96.1 bootstrap.
    rustup which cargo --toolchain "$STOCK_TC" 2>/dev/null
}

build_variant() {
    local label="$1"   # short name used in paths
    local config_extra="$2"   # extra RUSTFLAGS_NOT_BOOTSTRAP for the build
    local build_dir="${3:-$ROOT/build-stage2-$label}"

    if [ -x "$build_dir/x86_64-unknown-linux-gnu/stage2/bin/rustc" ]; then
        echo "  [cached] $label already built"
        return 0
    fi

    echo "  Building $label (this takes ~20-60 min)..."
    RUSTFLAGS_NOT_BOOTSTRAP="$config_extra" \
        python3 "$ROOT/x.py" build --stage 2 compiler/rustc library/std \
        --build-dir "$build_dir" -j 4 2>&1 | tail -1
    echo "  Done building $label"
}

bench_variant() {
    local label="$1"
    local rustc="$2"
    local cargo="$3"

    if [ ! -x "$rustc" ]; then
        echo "  SKIP: $label — binary not found at $rustc"
        return
    fi

    echo ""
    # Pre-populate shared LLVM cache so it's not re-downloaded per run
    mkdir -p "$CACHE_DIR"
    if [ ! -d "$CACHE_DIR/llvm-cache" ]; then
        echo "  Pre-downloading LLVM..."
        # Do one throwaway build to populate the cache, then keep the cache dir
        local warmup="/tmp/rustc-bench-warmup-$label"
        rm -rf "$warmup"
        python3 "$ROOT/x.py" build --stage 1 \
            --set build.rustc="$rustc" --set build.cargo="$cargo" \
            library/std compiler/rustc --build-dir "$warmup" -j 4 2>&1 | tail -1
        # Move the cache to a shared location
        mv "$warmup/cache" "$CACHE_DIR/llvm-cache" 2>/dev/null || true
        rm -rf "$warmup"
        echo "  LLVM cached."
    fi

    echo ""
    echo "--- $label ---"
    echo "  rustc: $rustc"
    for run in $(seq 1 $RUNS); do
        local bdir="/tmp/rustc-bench-$label-run-$run"
        rm -rf "$bdir"
        mkdir -p "$bdir"
        # Symlink the shared LLVM cache into the fresh build directory
        ln -sfn "$CACHE_DIR/llvm-cache" "$bdir/cache" 2>/dev/null || true
        local wall
        wall=$(/usr/bin/time -f '%e' python3 "$ROOT/x.py" build --stage 1 \
            --set build.rustc="$rustc" --set build.cargo="$cargo" \
            library/std compiler/rustc --build-dir "$bdir" -j 4 2>&1 | tail -1 2>&1)
        echo "  Run $run: ${wall}s"
        echo "$label run $run: ${wall}s" >> "$RESULTS"
    done
}

# ----- Step 1: Build all variants -----
echo ""
echo "=== Step 1: Building compiler variants ==="

# Stock is already installed via rustup
echo "  [cached] Stock $STOCK_TC"

# PGSO stable: build with the PGSO opt-level lists
# Uses channel=stable from config.toml, applies PGSO via RUSTFLAGS_NOT_BOOTSTRAP
build_variant "pgso-stable" \
    "-Z hot-cold-split -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels.txt -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels.txt"

# PGSO nightly: change config to nightly, rebuild
build_variant "pgso-nightly" \
    "-Z hot-cold-split -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels.txt -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels.txt" \
    "/tmp/pgso-pgso-almalinux8"

# Os-optimized: compile all compiler code with -C opt-level=s
build_variant "os" "-C opt-level=s"

# ----- Step 2: Benchmark each variant -----
echo ""
echo "=== Step 2: Benchmarking ==="
rm -f "$RESULTS"

bench_variant "stock" \
    "$(rustc_path stock)" "$(cargo_path stock)"

bench_variant "pgso-stable" \
    "$(rustc_path pgso-stable)" "$(cargo_path pgso-stable)"

bench_variant "pgso-nightly" \
    "$(rustc_path pgso-nightly)" "$(cargo_path pgso-nightly)"

bench_variant "os" \
    "$(rustc_path os)" "$(cargo_path os)"

# ----- Step 3: Summary -----
echo ""
echo "========================================================================="
echo "  Results"
echo "========================================================================="
echo ""
printf "%-20s %12s %12s %12s\n" "Configuration" "Run 1" "Run 2" "Run 3"
echo "-----------------------------------------------------------------"

for variant in stock pgso-stable pgso-nightly os; do
    runs=($(grep "^$variant " "$RESULTS" 2>/dev/null | awk '{print $3}'))
    if [ ${#runs[@]} -eq 3 ]; then
        printf "%-20s %10.1fs %10.1fs %10.1fs\n" "$variant" "${runs[0]}" "${runs[1]}" "${runs[2]}"
    fi
done

echo ""
echo "See CGU_TIERING_ANALYSIS.md for interpretation."
