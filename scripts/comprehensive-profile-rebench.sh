#!/usr/bin/env bash
# Re-run just the benchmarks from comprehensive-profile.sh, in round-robin
# order (all variants for run 1, then all variants for run 2, etc.) to
# reduce systematic timing bias from system load drift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="/tmp/bench-variants-roundrobin.txt"
RUNS=3
STOCK_CARGO="$(rustup which cargo --toolchain 1.96.1)"
STOCK_RUSTC="$(rustup which rustc --toolchain 1.96.1)"

declare -a LABELS=()
declare -a RUSTCS=()
declare -a SOS=()

add_variant() {
    LABELS+=("$1")
    RUSTCS+=("$2")
    SOS+=("$3")
}

stock_so=$(find /root/.rustup/toolchains/1.96.1-x86_64-unknown-linux-gnu/lib/ -maxdepth 1 -name 'librustc_driver-*.so' | head -1)
add_variant "stock"   "$STOCK_RUSTC" "$stock_so"
for label in o3 pgso-o3 pgsos pgso pgso10 pgso100 os base; do
    bdir="$ROOT/build-stage2-$label"
    add_variant "$label" \
        "$bdir/x86_64-unknown-linux-gnu/stage2/bin/rustc" \
        "$bdir/x86_64-unknown-linux-gnu/stage2-rustc/x86_64-unknown-linux-gnu/release/librustc_driver.so"
done

echo "============================================================"
echo "  PGSO Benchmarks (round-robin)"
echo "============================================================"
rm -f "$RESULTS"

# Print size header
echo ""
echo "Compiler sizes:"
for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"
    so="${SOS[$i]}"
    size="?"
    if [ -f "$so" ]; then
        size=$(stat -c%s "$so" 2>/dev/null)
        size="$(numfmt --to=iec $size 2>/dev/null || echo "${size}B")"
    fi
    printf "  %-10s %s\n" "$label" "$size"
done

for run in $(seq 1 $RUNS); do
    echo ""
    echo "--- Run $run ---"
    for i in "${!LABELS[@]}"; do
        label="${LABELS[$i]}"
        rustc="${RUSTCS[$i]}"
        if [ ! -x "$rustc" ]; then
            echo "  SKIP $label (no binary)"
            continue
        fi
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

echo ""
echo "=== Results ==="
cat "$RESULTS"
echo ""
echo "Done."
