#!/usr/bin/env bash
# Benchmark compiler speed: time to compile a large Cargo project
# with different compilers, default settings only (no PGSO flags).
set -euo pipefail

BENCH_DIR="/tmp/bench-compile"
STOCK="1.96.1"
PGSO="pgso-almalinux8"

echo "== Compiler speed benchmark =="
echo "Builds a large Cargo project from clean state (deps pre-downloaded)"
echo "No PGSO flags — pure compiler comparison."
echo ""

# Create benchmark project: depends on serde_json + syn (large crates)
rm -rf "$BENCH_DIR"
cargo init "$BENCH_DIR" 2>/dev/null

cat > "$BENCH_DIR/Cargo.toml" <<'EOF'
[package]
name = "bench-compile"
version = "0.1.0"
edition = "2021"

[dependencies]
serde_json = "1.0"
serde = { version = "1.0", features = ["derive"] }
syn = { version = "2.0", features = ["full", "extra-traits"] }
proc-macro2 = "1.0"
quote = "1.0"
EOF

cat > "$BENCH_DIR/src/main.rs" <<'EOF'
use serde::Deserialize;
use syn::parse_file;

#[derive(Deserialize)]
struct Data { name: String, values: Vec<f64> }

fn main() {
    let json = r#"{"name":"test","values":[1.0,2.0,3.0]}"#;
    for _ in 0..1000 {
        let _: Data = serde_json::from_str(json).unwrap();
    }
    let ast = parse_file("fn hello() -> u32 { 42 }").unwrap();
    println!("items: {}", ast.items.len());
}
EOF

# Pre-download for both toolchains
echo "Pre-downloading dependencies..."
for tc in "$STOCK" "$PGSO"; do
  cargo "+$tc" fetch --manifest-path "$BENCH_DIR/Cargo.toml" 2>/dev/null
done

run_bench() {
    local label="$1"
    local toolchain="$2"
    local tdir="$BENCH_DIR/target-$toolchain"

    # Warm build (populates dep cache)
    rm -rf "$tdir"
    CARGO_TARGET_DIR="$tdir" cargo "+$toolchain" build --release \
      --manifest-path "$BENCH_DIR/Cargo.toml" 2>/dev/null

    echo ""
    echo "--- $label ---"
    for run in 1 2 3; do
        rm -rf "$tdir"
        local wall
        wall=$(/usr/bin/time -f '%e' sh -c "
          CARGO_TARGET_DIR='$tdir' cargo '+$toolchain' build --release \
            --manifest-path '$BENCH_DIR/Cargo.toml' 2>&1 | tail -1
        " 2>&1 | tail -1)
        echo "  Run $run: ${wall}s"
    done
}

run_bench "Stock $STOCK" "$STOCK"
run_bench "PGSO $PGSO" "$PGSO"
