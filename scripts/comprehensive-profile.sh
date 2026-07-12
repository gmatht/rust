#!/usr/bin/env bash
# Comprehensive PGSO profiling and benchmarking pipeline.
# Builds diverse profiles of rustc, generates opt-level files at multiple
# threshold levels, builds compiler variants, and benchmarks them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGO_DIR="$ROOT/build/pgo_data/profiles"
PGO_DATA="$ROOT/build/pgo_data"
RESULTS="/tmp/bench-variants.txt"
STOCK_CARGO="$(rustup which cargo --toolchain 1.96.1)"
STOCK_RUSTC="$(rustup which rustc --toolchain 1.96.1)"
RUNS=3

mkdir -p "$PGO_DIR"
cd "$ROOT"

echo "========================================================================="
echo "  Comprehensive PGSO Profiling & Benchmarking"
echo "========================================================================="

# ---- Step 1: Build instrumented compiler ----
echo ""
echo "=== Step 1: Build instrumented PGSO compiler ==="
INSTRUMENTED_RUSTC="$ROOT/build/x86_64-unknown-linux-gnu/stage2/bin/rustc"
if [ -x "$INSTRUMENTED_RUSTC" ]; then
    echo "  (cached, skipping)"
else
    local logfile="$PGO_DATA/build-instrumented.log"
    RUSTFLAGS_NOT_BOOTSTRAP="-Z human-readable-cgu-names -Z hot-cold-split \
      -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels.txt \
      -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels.txt" \
    python3 x.py build --stage 2 compiler/rustc library/std \
      --rust-profile-generate="$PGO_DIR" -j 4 2>&1 | tee "$logfile"
    first_warn=$(grep -m1 "warning:" "$logfile" | grep -v "generated" || true)
    [ -n "$first_warn" ] && echo "  Example warning: $first_warn"
fi

# ---- Step 2: Diverse training workloads ----
echo ""
echo "=== Step 2: Running diverse training workloads ==="

export LLVM_PROFILE_FILE="$PGO_DIR/train-%m.profraw"
HOST_TRIPLE="x86_64-unknown-linux-gnu"
TAG=$(date +%s)  # unique tag to force clean compilation each run

# cargo-based training: forces full recompilation of all deps through the
# instrumented compiler using a unique --target-dir per run.
train_crate() {
    local label="$1"
    local manifest="$2"
    echo "  [$label] Building..."
    RUSTC="$INSTRUMENTED_RUSTC" CARGO="$STOCK_CARGO" \
        cargo build --release --manifest-path "$manifest" \
        --target-dir "/tmp/train-cargo-$label-$TAG"
}

# Setup training projects (preserve source across runs)
ensure_project() {
    local dir="$1"
    if [ -f "$dir/Cargo.toml" ]; then
        return 0
    fi
    cargo init --lib "$dir" 2>&1
}

ensure_project "$ROOT/train-no-std"
if [ ! -f "$ROOT/train-no-std/src/lib.rs" ]; then
    echo '#![no_std]' > "$ROOT/train-no-std/src/lib.rs"
fi

ensure_project "$ROOT/train-serde"
if [ ! -f "$ROOT/train-serde/Cargo.toml" ]; then
    cat > "$ROOT/train-serde/Cargo.toml" <<'EOF'
[package] name = "train-serde" version = "0.1.0" edition = "2021"
[dependencies] serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
EOF
    cat > "$ROOT/train-serde/src/lib.rs" <<'RUST'
use serde::Deserialize;
#[derive(Deserialize)]
struct Data { name: String, values: Vec<f64> }
pub fn parse(j: &str) -> Data { serde_json::from_str(j).unwrap() }
RUST
fi

ensure_project "$ROOT/train-syn"
if [ ! -f "$ROOT/train-syn/Cargo.toml" ]; then
    cat > "$ROOT/train-syn/Cargo.toml" <<'EOF'
[package] name = "train-syn" version = "0.1.0" edition = "2021"
[dependencies] syn = { version = "2.0", features = ["full"] } quote = "1.0"
EOF
    cat > "$ROOT/train-syn/src/lib.rs" <<'RUST'
pub fn parse_rust(code: &str) -> String {
    let file: syn::File = syn::parse_file(code).unwrap();
    quote::quote!(#file).to_string()
}
RUST
fi

# Run training workloads — each forces full recompile via unique target dir
rm -f "$PGO_DIR"/*.profraw "$ROOT"/default_*.profraw
train_crate "no-std"     "$ROOT/train-no-std/Cargo.toml"
train_crate "serde-json" "$ROOT/train-serde/Cargo.toml"
train_crate "syn"        "$ROOT/train-syn/Cargo.toml"

echo ""
echo "Profiles: $(ls "$PGO_DIR"/*.profraw 2>/dev/null | wc -l) files, $(du -sh "$PGO_DIR" | cut -f1)"

# ---- Step 3: Merge profiles and generate opt-level files ----
echo ""
echo "=== Step 3: Merging profiles ==="
CI_LLVM_PD="$ROOT/build/x86_64-unknown-linux-gnu/ci-llvm/bin/llvm-profdata"
[ -x "$CI_LLVM_PD" ] || CI_LLVM_PD=$(find /root/.rustup/toolchains -name llvm-profdata -type f 2>/dev/null | head -1)
"$CI_LLVM_PD" merge -o "$PGO_DATA/merged.profdata" "$PGO_DIR"/*.profraw 2>&1
echo "Merged: $(ls -lh "$PGO_DATA/merged.profdata" | awk '{print $5}')"

echo ""
echo "=== Step 4: Generating opt-level files ==="
declare -A CLASSIFIED
gen_opts() {
    local label="$1" hot="$2" warm="$3" tepid="$4" suffix="$5"
    local out
    if [ "$hot" = "0" ] && [ "$warm" = "0" ] && [ "$tepid" = "0" ]; then
        out=$(python3 "$ROOT/src/tools/generate_opt_levels.py" \
            --profdata "$PGO_DATA/merged.profdata" \
            --llvm-profdata "$CI_LLVM_PD" --o3-everything)
    else
        out=$(python3 "$ROOT/src/tools/generate_opt_levels.py" \
            --profdata "$PGO_DATA/merged.profdata" \
            --llvm-profdata "$CI_LLVM_PD" \
            --hot-threshold "$hot" --warm-threshold "$warm" --tepid-threshold "$tepid")
    fi
    # Extract classified count: "Wrote /tmp/fn_opt_levels.txt (N classified)"
    local count
    count=$(echo "$out" | grep -oP '\(\K[0-9]+(?= classified)')
    CLASSIFIED[$label]=$count
    echo "  $label: $count classified @ hot=$hot warm=$warm tepid=$tepid"
    cp /tmp/fn_opt_levels.txt "$ROOT/build/pgo_data/fn_opt_levels_${suffix}.txt"
    cp /tmp/cgu_opt_levels.txt "$ROOT/build/pgo_data/cgu_opt_levels_${suffix}.txt"
}

# Multiply formula: higher factor = larger divisor = lower threshold = MORE O3
# pgso100 > pgso10 > pgso > pgsos
for factor in 1 10 100; do
    gen_opts "pgso${factor}x" "$((100 * factor))" "$((500 * factor))" "$((2000 * factor))" "${factor}x"
done

# pgsos: 10x stricter than pgso (divisor 10 instead of 100) → less O3
gen_opts "pgsos" "10" "50" "200" "sos"

# O3-everything
gen_opts "pgso-o3" "0" "0" "0" "o3"

# Assert O3-function monotonic ordering: pgsos < pgso < pgso10 < pgso100
o3_count() { grep -c ' O3$' "$ROOT/build/pgo_data/fn_opt_levels_$1.txt" 2>/dev/null || echo 0; }
O3_PGSOS=$(o3_count sos)
O3_PGSO=$(o3_count 1x)
O3_PGSO10=$(o3_count 10x)
O3_PGSO100=$(o3_count 100x)

if [ "$O3_PGSOS" -lt "$O3_PGSO" ]; then
    echo "  [OK] pgsos O3 ($O3_PGSOS) < pgso O3 ($O3_PGSO)"
else
    echo "  [FAIL] pgsos O3 ($O3_PGSOS) should be < pgso O3 ($O3_PGSO)" >&2
    exit 1
fi
if [ "$O3_PGSO" -lt "$O3_PGSO10" ]; then
    echo "  [OK] pgso O3 ($O3_PGSO) < pgso10 O3 ($O3_PGSO10)"
else
    echo "  [FAIL] pgso O3 ($O3_PGSO) should be < pgso10 O3 ($O3_PGSO10)" >&2
    exit 1
fi
if [ "$O3_PGSO10" -lt "$O3_PGSO100" ]; then
    echo "  [OK] pgso10 O3 ($O3_PGSO10) < pgso100 O3 ($O3_PGSO100)"
else
    echo "  [FAIL] pgso10 O3 ($O3_PGSO10) should be < pgso100 O3 ($O3_PGSO100)" >&2
    exit 1
fi

echo ""
echo "=== Step 5: Building compiler variants ==="
build_variant() {
    local label="$1"
    local flags="$2"
    local bdir="$ROOT/build-stage2-$label"
    local rustc_bin="$bdir/x86_64-unknown-linux-gnu/stage2/bin/rustc"
    local build_log="${TMPDIR:-/tmp}/build-${label}.log"
    local times_log="$PGO_DATA/build-variant-times.log"

    if [ -x "$rustc_bin" ]; then
        local bin_time
        bin_time=$(stat -c%Y "$rustc_bin" 2>/dev/null || echo 0)
        for word in $flags; do
            case "$word" in
                cgu-opt-levels=*|fn-opt-levels=*)
                    optfile="${word#*=}"
                    if [ -f "$optfile" ] && [ "$(stat -c%Y "$optfile" 2>/dev/null)" -gt "$bin_time" ]; then
                        echo "  [stale] $label (opt-level file newer)"
                        rm -rf "$bdir"
                        break
                    fi
                    ;;
            esac
        done
    fi

    local start_time=$(date +%s)

    if [ -x "$rustc_bin" ]; then
        echo "  [cached] $label"
    else
        echo "  Building $label... (log: $build_log)"
        RUSTFLAGS_NOT_BOOTSTRAP="$flags" \
            python3 x.py build --stage 2 compiler/rustc library/std \
            --build-dir "$bdir" -j 4 2>&1 | tee "$build_log"
        first_warn=$(grep -m1 "warning:" "$build_log" | grep -v "generated" || true)
        [ -n "$first_warn" ] && echo "  Example warning: $first_warn"
    fi

    local end_time=$(date +%s)
    local dir_size=$(du -sb "$bdir" 2>/dev/null | cut -f1 || echo 0)
    local elapsed=$((end_time - start_time))
    [ -x "$rustc_bin" ] && elapsed="cached"
    echo "$label ${elapsed}s ${dir_size}" >> "$times_log"
    echo "  $label: ${elapsed}s, $(numfmt --to=iec "$dir_size" 2>/dev/null || echo "$dir_size bytes")"
}

build_variant "pgsos" "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels_sos.txt -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels_sos.txt"
build_variant "pgso" "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels_1x.txt -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels_1x.txt"
build_variant "Def_O3" "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels_1x.txt -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels_1x.txt -Z cgu-opt-level-default=O3 -Z fn-opt-level-default=O3"
build_variant "pgso10" "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels_10x.txt -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels_10x.txt"
build_variant "pgso100" "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels_100x.txt -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels_100x.txt"
build_variant "pgso-o3" "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=$ROOT/build/pgo_data/cgu_opt_levels_o3.txt -Z fn-opt-levels=$ROOT/build/pgo_data/fn_opt_levels_o3.txt"
build_variant "o3" "-C opt-level=3"
build_variant "os" "-C opt-level=s"
build_variant "oz" "-C opt-level=z"
build_variant "base" ""

# ---- Step 6: Benchmark (round-robin) ----
echo ""
echo "=== Step 6: Benchmarking all variants ==="
rm -f "$RESULTS"

declare -a BENCH_LABELS=()
declare -a BENCH_RUSTCS=()
declare -a BENCH_SOS=()

add_bench() {
    local label="$1" rustc="$2" so="$3"
    [ ! -x "$rustc" ] && { echo "  SKIP $label (no binary)"; return; }
    BENCH_LABELS+=("$label")
    BENCH_RUSTCS+=("$rustc")
    BENCH_SOS+=("$so")
}

label_so() {
    local label="$1"
    case "$label" in
        stock) echo "$(find /root/.rustup/toolchains/1.96.1-x86_64-unknown-linux-gnu/lib/ -maxdepth 1 -name 'librustc_driver-*.so' | head -1)" ;;
        *) echo "$ROOT/build-stage2-$label/x86_64-unknown-linux-gnu/stage2-rustc/x86_64-unknown-linux-gnu/release/librustc_driver.so" ;;
    esac
}

label_rustc() {
    local label="$1"
    case "$label" in
        stock) echo "$STOCK_RUSTC" ;;
        *) echo "$ROOT/build-stage2-$label/x86_64-unknown-linux-gnu/stage2/bin/rustc" ;;
    esac
}

for label in stock o3 oz pgso-o3 pgsos pgso Def_O3 pgso10 pgso100 os base; do
    add_bench "$label" "$(label_rustc "$label")" "$(label_so "$label")"
done

# Show sizes
echo ""
echo "Compiler sizes:"
for i in "${!BENCH_LABELS[@]}"; do
    label="${BENCH_LABELS[$i]}"
    so="${BENCH_SOS[$i]}"
    size="?"
    if [ -f "$so" ]; then
        size=$(numfmt --to=iec "$(stat -c%s "$so")" 2>/dev/null)
    fi
    printf "  %-10s %s\n" "$label" "$size"
done

# Run all variants round-robin
for run in $(seq 1 $RUNS); do
    echo ""
    echo "--- Run $run ---"
    for i in "${!BENCH_LABELS[@]}"; do
        label="${BENCH_LABELS[$i]}"
        rustc="${BENCH_RUSTCS[$i]}"
        bdir="/tmp/bench-rr-$label-run$run"
        rm -rf "$bdir"

        echo -n "  $label ... "
        wall=$(/usr/bin/time -f '%e' python3 "$ROOT/x.py" build --stage 1 compiler/rustc \
            --set build.rustc="$rustc" --set build.cargo="$STOCK_CARGO" \
            --build-dir "$bdir" -j 4 2>&1 | tail -1 2>&1)
        echo "${wall}s"
        echo "$label $run $wall" >> "$RESULTS"
    done
done

# ---- Step 7: Size comparison ----
echo ""
echo "=== Step 7: Sizes ==="
for label in stock pgsos pgso Def_O3 pgso10 pgso100 pgso-o3 o3 oz os base; do
    case "$label" in
        stock) so=$(find /root/.rustup/toolchains/1.96.1-x86_64-unknown-linux-gnu/lib/ -maxdepth 1 -name 'librustc_driver-*.so' | head -1) ;;
        *) so="$ROOT/build-stage2-$label/x86_64-unknown-linux-gnu/stage2-rustc/x86_64-unknown-linux-gnu/release/librustc_driver.so" ;;
    esac
    if [ -f "$so" ]; then
        size=$(stat -c%s "$so" 2>/dev/null)
        printf "%-10s %'d bytes (%d MB)\n" "$label" "$size" "$((size / 1048576))"
    fi
done

echo ""
echo "=== Results ==="
cat "$RESULTS" 2>/dev/null || echo "(no results)"
echo ""
echo "Done."
