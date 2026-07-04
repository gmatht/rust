#!/usr/bin/env bash
# Benchmark: time to build rustc itself with each compiler.
# Both build the same source with default config (no PGSO flags).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOCK="1.96.1"
PGSO="pgso-almalinux8"

echo "== Rustc build speed benchmark =="
echo "Measures: clean build of rustc via x.py --stage 1 (no PGSO flags)"
echo "Note: stage0 is identical in both cases (downloaded CI compiler)."
echo "      The PGSO compiler is used as the stage1->stage2 compiler,"
echo "      so stage2 build time is the meaningful comparison."
echo ""

cd "$ROOT"

run_bench() {
    local label="$1"
    local toolchain="$2"
    local build_dir="/tmp/rustc-bench-$toolchain"

    echo "--- $label ---"
    for run in 1 2 3; do
        rm -rf "$build_dir"
        echo "  Run $run..."
        local wall
        wall=$(/usr/bin/time -f '%e' python3 "$ROOT/x.py" build --stage 1 \
            library/std compiler/rustc --build-dir "$build_dir" 2>&1 | tail -1 2>&1)
        echo "  Run $run: ${wall}s"
    done
}

run_bench "Stock $STOCK" "$STOCK"
run_bench "PGSO $PGSO" "$PGSO"
