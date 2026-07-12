#!/usr/bin/env bash
# Quick re-measure: regenerates CSV data from existing rlibs without rebuilding.
set -eo pipefail

ROOT="/root/src/rustloop/rust1.96"
PGO_DATA="$ROOT/build/pgo_data"
RESULTS_LOG="$PGO_DATA/brute-quick-results.csv"
CRATES_LOG="$PGO_DATA/brute-quick-crates.csv"

# Delete empty CSVs
rm -f "$RESULTS_LOG" "$CRATES_LOG"

# Results header
echo "unix_ts,level,build_time_s,final_size,peak_mem_bytes,total_cpu_ns,peak_cpu_ns_per_sec" > "$RESULTS_LOG"
echo "level,crate,text_size" > "$CRATES_LOG"

# Map directory names to level names
declare -A DIR_MAP
DIR_MAP["build-brute-quick-Os"]="Os"
DIR_MAP["build-brute-quick-O1"]="O1"
DIR_MAP["build-brute-quick-O2"]="O2"
DIR_MAP["build-brute-quick-O3"]="O3"

for dir_name in "${!DIR_MAP[@]}"; do
    level="${DIR_MAP[$dir_name]}"
    build_dir="$ROOT/$dir_name"
    
    if [ ! -d "$build_dir" ]; then
        echo "  SKIP $level: $dir_name not found"
        continue
    fi
    echo "Measuring $level from $dir_name ..."
    
    # Find the .so
    so=$(find "$build_dir" -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' 2>/dev/null | head -1)
    final_size=0
    if [ -n "$so" ]; then
        final_size=$(stat -c%s "$so")
    fi
    
    # Log results row (no build time, no peak mem)
    echo "0,$level,0,$final_size,0,0,0" >> "$RESULTS_LOG"
    
    # Measure all rlibs
    crates_measured=0
    for rlib_dir in "$build_dir"/x86_64-unknown-linux-gnu/stage2-rustc/*/release/deps \
                    "$build_dir"/x86_64-unknown-linux-gnu/stage2-rustc/release/deps \
                    "$build_dir"/x86_64-unknown-linux-gnu/stage2/lib/rustlib/*/lib; do
        [ -d "$rlib_dir" ] || continue
        for rlib in "$rlib_dir"/*.rlib; do
            [ -f "$rlib" ] || continue
            base=$(basename "$rlib" .rlib)
            crate=${base#lib}
            crate=${crate%-*}
            text=$(size --format=berkeley "$rlib" 2>/dev/null | tail -n +2 | awk '{sum += $1} END {print sum}')
            if [ -n "$text" ] && [ "$text" -gt 0 ]; then
                echo "$level,$crate,$text" >> "$CRATES_LOG"
                crates_measured=$((crates_measured + 1))
            fi
        done
    done
    echo "  -> $crates_measured crates, driver=$final_size bytes"
done

echo ""
echo "Done. Results:"
echo "  $RESULTS_LOG ($(wc -l < "$RESULTS_LOG") rows)"
echo "  $CRATES_LOG ($(wc -l < "$CRATES_LOG") rows)"
