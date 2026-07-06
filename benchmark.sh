#!/usr/bin/env bash
# Reproduce the PGSO benchmark from CGU_TIERING_ANALYSIS.md.
# Pre-downloads dependencies, then times clean builds.
set -euo pipefail

BENCH_DIR="/tmp/pgso-bench"
STOCK="1.96.1"
PGSO="pgso-almalinux8"
ROOT="$(cd "$(dirname "$0")" && pwd)"
FN_OPTS="$ROOT/build/pgo_data/fn_opt_levels.txt"
CGU_OPTS="$ROOT/build/pgo_data/cgu_opt_levels.txt"

echo "== PGSO Benchmark =="
echo "Measures: cargo build --release -j1 (clean build, deps pre-downloaded)"
echo ""

# Create benchmark project
rm -rf "$BENCH_DIR"
cargo init "$BENCH_DIR" 2>/dev/null

cat > "$BENCH_DIR/Cargo.toml" <<'EOF'
[package]
name = "pgso-bench"
version = "0.1.0"
edition = "2021"

[dependencies]
serde_json = "1.0"
serde = { version = "1.0", features = ["derive"] }
EOF

cat > "$BENCH_DIR/src/main.rs" <<'EOF'
use serde::Deserialize;

#[derive(Deserialize)]
struct Data {
    name: String,
    values: Vec<f64>,
}

fn main() {
    let json = r#"{"name":"test","values":[1.0,2.0,3.0,4.0,5.0]}"#;
    for _ in 0..10000 {
        let _: Data = serde_json::from_str(json).unwrap();
    }
}
EOF

# Pre-download dependencies (network fetch only, not compilation)
echo "Pre-downloading dependencies..."
for tc in "$STOCK" "$PGSO"; do
  CARGO_TARGET_DIR="$BENCH_DIR/target-$tc" cargo "+$tc" fetch --manifest-path "$BENCH_DIR/Cargo.toml" 2>/dev/null
done

run_bench() {
    local label="$1"
    local toolchain="$2"
    local cache_dir="$BENCH_DIR/cache-$toolchain"
    local extra_flags="${3:-}"

    # Warm: build once to cache compiled deps
    rm -rf "$BENCH_DIR/target-$toolchain"
    CARGO_TARGET_DIR="$BENCH_DIR/target-$toolchain" \
    RUSTFLAGS="$extra_flags" \
      cargo "+$toolchain" build --release -j1 --manifest-path "$BENCH_DIR/Cargo.toml" 2>/dev/null

    echo ""
    echo "--- $label ---"
    for run in 1 2 3; do
        # Flush build artifacts but keep registry/index cache
        rm -rf "$BENCH_DIR/target-$toolchain"
        local wall
        wall=$(/usr/bin/time -f '%e' sh -c '
          CARGO_TARGET_DIR="$0" RUSTFLAGS="$1" cargo "+$2" build --release -j1 --manifest-path "$3" 2>&1 | tail -1
        ' "$BENCH_DIR/target-$toolchain" "$extra_flags" "$toolchain" "$BENCH_DIR/Cargo.toml" 2>&1 | tail -1)
        echo "  Run $run: ${wall}s"
    done
}

# 1. Stock 1.96.1
run_bench "Stock 1.96.1" "$STOCK"

# 2. PGSO (no extra flags)
run_bench "PGSO (no flags)" "$PGSO"

# 3. PGSO + fn-opt-levels
run_bench "PGSO + fn-opt-levels" "$PGSO" "-Z fn-opt-levels=$FN_OPTS -Z cgu-opt-levels=$CGU_OPTS -Z hot-cold-split"
