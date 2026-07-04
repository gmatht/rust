#!/usr/bin/env bash
# Benchmark: time to build rustc itself with each compiler as stage0.
# Both build the same source with default config (no PGSO flags).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOCK_TC="1.96.1"
PGSO_TC="pgso-almalinux8"

echo "== Rustc build speed benchmark =="
echo "Measures: clean stage1 build using each compiler as stage0"
echo "Config: default (no PGSO flags), -j 4"
echo ""

cd "$ROOT"

rustc_path() {
    local tc="$1"
    if [ "$tc" = "$STOCK_TC" ]; then
        rustup which rustc --toolchain "$tc" 2>/dev/null
    else
        echo "/tmp/pgso-pgso-almalinux8/bin/rustc"
    fi
}

cargo_path() {
    local tc="$1"
    if [ "$tc" = "$STOCK_TC" ]; then
        rustup which cargo --toolchain "$tc" 2>/dev/null
    else
        echo "/tmp/pgso-pgso-almalinux8/bin/cargo"
    fi
}

run_bench() {
    local label="$1"
    local toolchain="$2"
    local build_dir="/tmp/rustc-bench-$toolchain"
    local rc=$(rustc_path "$toolchain")
    local cg=$(cargo_path "$toolchain")

    echo "--- $label ---"
    echo "  rustc: $rc"
    echo "  cargo: $cg"
    for run in 1 2 3; do
        rm -rf "$build_dir"
        echo "  Run $run..."
        local wall
        wall=$(/usr/bin/time -f '%e' python3 "$ROOT/x.py" build --stage 1 \
            --set build.rustc="$rc" --set build.cargo="$cg" \
            library/std compiler/rustc --build-dir "$build_dir" -j 4 2>&1 | tail -1 2>&1)
        echo "  Run $run: ${wall}s"
    done
}

run_bench "Stock $STOCK_TC" "$STOCK_TC"
run_bench "PGSO $PGSO_TC" "$PGSO_TC"
