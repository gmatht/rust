#!/usr/bin/env bash
# Quick brute-force CGU opt-level optimizer.
# Builds the compiler at each global opt level (Oz, Os, O1, O2, O3),
# measures per-crate code sizes (text section from rlibs), and selects
# the smallest opt-level per crate that is at least as speed-optimised
# as the PGSO default.
#
# --size-tweaks : additionally tests O2 and O3 variants with adjusted
#   LLVM codegen flags that favour size (no loop unrolling, conservative
#   inlining, no auto-vectorisation).  These variants then compete in
#   the per-crate selection alongside the standard levels.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGO_DATA="$ROOT/build/pgo_data"
BUILD_DIR="$ROOT/build-brute-quick"
JOBS=4

# When --parallel is active, multiple builds run concurrently.
# Cap per-build jobs to 1 to avoid OOM (each build gets 1 core).
# Override with JOBS=N env var for more aggressive parallelism.
: "${PARALLEL_JOBS:=1}"

FN_FILE="$PGO_DATA/fn_opt_levels_1x.txt"
PGSO_BASELINE="$PGO_DATA/cgu_opt_levels_1x.txt"

RESULTS_LOG="$PGO_DATA/brute-quick-results.csv"
CRATES_LOG="$PGO_DATA/brute-quick-crates.csv"
SUMMARY_LOG="$PGO_DATA/brute-quick-summary.csv"
OPT_FILE_FINAL="$PGO_DATA/cgu_opt_levels_brute_quick.txt"
BUILD_LOG_DIR="/tmp/brute-quick-logs"
mkdir -p "$BUILD_LOG_DIR"

# Standard levels
LEVELS=(Oz Os O1 O2 O3)
# Speed ordering from least to most speed-optimised
declare -A SPEED_RANK
SPEED_RANK[Oz]=0
SPEED_RANK[Os]=1
SPEED_RANK[O1]=2
SPEED_RANK[O2]=3
SPEED_RANK[O3]=4

# ---- Size-tweak configuration ----
# These are O2/O3 variants with LLVM flags that inhibit code-size
# increasing transformations (loop unrolling, vectorisation, overly
# aggressive inlining).  They share the base level's speed rank so
# they are preferred only when strictly smaller.
SIZE_TWEAKS=false

# Base level + extra LLVM args for each tweak
declare -A TWEAK_BASE
declare -A TWEAK_ARGS

SIZE_TWEAK_NAMES=(
    "O2-no-unroll"
    "O2-no-unroll-no-vec"
    "O2-conservative-inline"
    "O3-no-unroll"
    "O3-no-unroll-no-vec"
    "O3-conservative-inline"
)

populate_tweak_tables() {
    # O2 tweaks
    TWEAK_BASE["O2-no-unroll"]="O2"
    TWEAK_ARGS["O2-no-unroll"]="-C llvm-args=-unroll-threshold=0"

    TWEAK_BASE["O2-no-unroll-no-vec"]="O2"
    TWEAK_ARGS["O2-no-unroll-no-vec"]="-C llvm-args=-unroll-threshold=0 -C llvm-args=-vectorize-loops=0 -C llvm-args=-vectorize-slp=0"

    TWEAK_BASE["O2-conservative-inline"]="O2"
    TWEAK_ARGS["O2-conservative-inline"]="-C llvm-args=-inline-threshold=50"

    # O3 tweaks
    TWEAK_BASE["O3-no-unroll"]="O3"
    TWEAK_ARGS["O3-no-unroll"]="-C llvm-args=-unroll-threshold=0"

    TWEAK_BASE["O3-no-unroll-no-vec"]="O3"
    TWEAK_ARGS["O3-no-unroll-no-vec"]="-C llvm-args=-unroll-threshold=0 -C llvm-args=-vectorize-loops=0 -C llvm-args=-vectorize-slp=0"

    TWEAK_BASE["O3-conservative-inline"]="O3"
    TWEAK_ARGS["O3-conservative-inline"]="-C llvm-args=-inline-threshold=50"

    # Assign speed rank = same as base level (so a tweak only wins when it's
    # strictly smaller than the plain base level — never when it's a tie).
    for tn in "${SIZE_TWEAK_NAMES[@]}"; do
        base="${TWEAK_BASE[$tn]}"
        SPEED_RANK["$tn"]=${SPEED_RANK[$base]}
    done
}

is_tweak() {
    local name="$1"
    [ -v "TWEAK_BASE[$name]" ]
}

cd "$ROOT"

# ---- Option parsing ----
EXISTING=false
REBUILD_DIR=""
PARALLEL=false
SKIP_EXISTING=false
extra_rustflags=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --existing) EXISTING=true; shift ;;
        --rebuild-dir) REBUILD_DIR="$2"; shift 2 ;;
        --parallel) PARALLEL=true; shift ;;
        --size-tweaks) SIZE_TWEAKS=true; shift ;;
        --skip-existing) SKIP_EXISTING=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Activate tweaks if requested
if [ "$SIZE_TWEAKS" = true ]; then
    populate_tweak_tables
    LEVELS+=("${SIZE_TWEAK_NAMES[@]}")
    echo "Size tweaks enabled: ${SIZE_TWEAK_NAMES[*]}"
fi

# Validate rebuild-dir argument
if [ -n "$REBUILD_DIR" ]; then
    case "$REBUILD_DIR" in
        Oz|Os|O1|O2|O3|final) ;;
        O2-no-unroll|O2-no-unroll-no-vec|O2-conservative-inline) ;;
        O3-no-unroll|O3-no-unroll-no-vec|O3-conservative-inline) ;;
        *) echo "Invalid --rebuild-dir value: '$REBUILD_DIR'"; exit 1 ;;
    esac
fi

# ---- Save/disable .cargo/config.toml ----
cleanup() {
    if [ -f ".cargo/config.toml.brute-quick-saved" ]; then
        mv .cargo/config.toml.brute-quick-saved .cargo/config.toml
        echo "Restored .cargo/config.toml"
    fi
}
trap cleanup EXIT
trap "echo ERROR at line \$LINENO >&2" ERR

if [ -f ".cargo/config.toml" ]; then
    mv .cargo/config.toml .cargo/config.toml.brute-quick-saved
    echo "Disabled .cargo/config.toml (saved as .cargo/config.toml.brute-quick-saved)"
fi

# ---- Infer opt-levels from existing rlib timestamps (--existing) ----
infer_from_existing() {
    echo ""
    echo "=== Inferring opt-levels from existing rlib timestamps ==="

    local deps_dir
    deps_dir=$(find "$BUILD_DIR" -type d -path '*/stage2-rustc/*/release/deps' 2>/dev/null | head -1)
    if [ -z "$deps_dir" ] || [ ! -d "$deps_dir" ]; then
        echo "ERROR: stage2-rustc deps directory not found in $BUILD_DIR" >&2
        return 1
    fi
    echo "  Using deps directory: $deps_dir"

    local tmpfile
    tmpfile=$(mktemp)

    # Collect all rlibs with (crate, mtime, path), sorted by crate then mtime
    for rlib in "$deps_dir"/*.rlib; do
        [ -f "$rlib" ] || continue
        local base crate mtime
        base=$(basename "$rlib" .rlib)
        crate=${base#lib}
        crate=${crate%-*}
        mtime=$(stat -c%Y "$rlib")
        echo "$crate $mtime $rlib"
    done | sort -k1,1 -k2,2n > "$tmpfile"

    # Group by crate name, assign levels by mtime order (oldest = Oz, newest = O3)
    local prev_crate="" idx
    local levels=(Oz Os O1 O2 O3)

    while IFS=' ' read -r crate mtime path; do
        if [ "$crate" != "$prev_crate" ]; then
            prev_crate="$crate"
            idx=0
        fi
        local level="${levels[$idx]:-}"
        if [ -n "$level" ]; then
            local text
            text=$(size --format=berkeley "$path" 2>/dev/null | tail -n +2 | awk '{sum += $1} END {print sum}')
            if [ -n "$text" ] && [ "$text" -gt 0 ]; then
                echo "$level,$crate,$text" >> "$CRATES_LOG"
            fi
        fi
        idx=$((idx + 1))
    done < "$tmpfile"

    rm "$tmpfile"
    local count
    count=$(tail -n +2 "$CRATES_LOG" 2>/dev/null | wc -l)
    echo "  Inferred $count (level,crate) pairs. Results in $CRATES_LOG"
}

# ---- Step 1: Create level-specific cgu_opt_levels files ----
echo ""
echo "========================================================================="
echo "  Step 1: Creating per-level cgu_opt_levels files"
echo "========================================================================="
for level in "${LEVELS[@]}"; do
    # Skip size-tweak levels — they reuse their base level's opt file
    is_tweak "$level" && continue
    out="$PGO_DATA/cgu_opt_levels_all_$level.txt"
    sed "s/ [^ ]*$/ $level/" "$PGSO_BASELINE" > "$out"
    echo "  Created $out"
done

# ---- Step 2: Build each level and measure ----
echo ""
echo "========================================================================="
echo "  Step 2: Building and measuring each global opt level"
echo "========================================================================="

# Build & measure a single level in a given build directory.
# Usage: build_and_measure <level> <build_dir>
build_and_measure() {
    local level="$1"
    local build_dir="$2"
    
    # If --skip-existing and we already have a non-zero entry for this level, skip
    if [ "$SKIP_EXISTING" = true ]; then
        if grep -q "^[0-9]*,$level," "$RESULTS_LOG" 2>/dev/null; then
            echo "  [SKIP] $level already has data in $RESULTS_LOG"
            return 0
        fi
    fi
    local optfile="$PGO_DATA/cgu_opt_levels_all_$level.txt"
    local logfile="$BUILD_LOG_DIR/build-$level.log"
    local peakfile="/tmp/brute-peak-${level}.txt"
    local cpufile="/tmp/brute-cpu-${level}"

    echo ""
    echo "=== Building $level (all crates at $level) in $build_dir ==="


    # Clean ALL stale rlibs (both compiler deps and std lib).  When the build
    # switches to a new opt level, cargo creates rlibs with new hash suffixes
    # but never deletes the old ones.  Per-crate text-size measurements then
    # see stale rlibs from previous levels, contaminating the data.
    clean_count=0
    for d in "$build_dir"/x86_64-unknown-linux-gnu/stage2-rustc/*/release/deps              "$build_dir"/x86_64-unknown-linux-gnu/stage2-rustc/release/deps              "$build_dir"/x86_64-unknown-linux-gnu/stage2/lib/rustlib/*/lib; do
        if [ -d "$d" ]; then
            n=$(find "$d" -name "*.rlib" 2>/dev/null | wc -l)
            find "$d" -name "*.rlib" -exec rm {} + 2>/dev/null || true
            clean_count=$((clean_count + n))
        fi
    done
    [ "$clean_count" -gt 0 ] && echo "  Cleaned $clean_count stale rlib(s)"
    # Disable LTO for measurement builds: rlibs contain real .text, builds are
    # ~2x faster, and the per-crate relative sizes are still the right signal.
    local start_ts
    start_ts=$(date +%s)

    # Run systemd-run in background so we can poll cgroup files from the outer script
    # Build the full RUSTFLAGS string (base flags + any size-tweak extras).
    local rustflags="-Z human-readable-cgu-names -Z hot-cold-split \
        -Z cgu-opt-levels=$optfile \
        -Z fn-opt-levels=$FN_FILE -Z fn-opt-level-default=Oz"
    if [ -n "$extra_rustflags" ]; then
        rustflags="$rustflags $extra_rustflags"
    fi

    systemctl stop "brute-quick-${level}.scope" 2>/dev/null || true
    systemd-run --scope --unit="brute-quick-${level}" \
        bash -c "
            cd '$ROOT'
            RUSTFLAGS_NOT_BOOTSTRAP='$rustflags' \
            python3 x.py build --stage 2 compiler/rustc library/std \
                --set rust.lto='off' \
                --build-dir '$build_dir' -j '${PARALLEL_JOBS}' > '$logfile' 2>&1
            rc=\$?
            echo -n \$(cat /sys/fs/cgroup/memory/system.slice/brute-quick-${level}.scope/memory.max_usage_in_bytes 2>/dev/null || echo 0) > '$peakfile'
            exit \$rc
        " &
    local build_pid=$!

    # Wait for cgroup to appear, then record start CPU
    local cpu_path="/sys/fs/cgroup/cpuacct/system.slice/brute-quick-${level}.scope/cpuacct.usage"
    local cpu_start=0
    local i=0
    while [ ! -f "$cpu_path" ] && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -f "$cpu_path" ] && cpu_start=$(cat "$cpu_path")

    # Poll for max CPU delta during the build
    local prev=$cpu_start
    local max_delta=0
    while kill -0 "$build_pid" 2>/dev/null; do
        sleep 1
        if [ -f "$cpu_path" ]; then
            local cur
            cur=$(cat "$cpu_path" 2>/dev/null || echo "$prev")
            local delta=$((cur - prev))
            [ "$delta" -gt "$max_delta" ] && max_delta=$delta
            prev=$cur
        fi
    done

    wait "$build_pid" 2>/dev/null || true

    local end_ts
    end_ts=$(date +%s)
    local build_time=$((end_ts - start_ts))

    # Read CPU stats (cgroup may still exist briefly)
    local cpu_end=$cpu_start
    [ -f "$cpu_path" ] && cpu_end=$(cat "$cpu_path" 2>/dev/null || echo "$cpu_end")
    local total_cpu_ns=$((cpu_end - cpu_start))

    if [ ! -f "$peakfile" ]; then
        # Build failed or was killed — read exit code from log tail
        echo "  ERROR: build failed (see $logfile)" >&2
        tail -5 "$logfile"
        return 1
    fi

    local peak_mem
    peak_mem=$(cat "$peakfile" 2>/dev/null || echo 0)
    rm -f "$peakfile"

    local so
    so=$(find "$build_dir" -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' | head -1)
    local final_size=0
    if [ -n "$so" ] && [ -f "$so" ]; then
        final_size=$(stat -c%s "$so")
    fi

    echo "$end_ts,$level,$build_time,$final_size,$peak_mem,$total_cpu_ns,$max_delta" >> "${RESULTS_LOG}-${level}"
    local mb=$((final_size / 1048576))
    local pmb=$((peak_mem / 1048576))
    local avg_cores=$(awk "BEGIN {printf \"%.1f\", $total_cpu_ns / $build_time / 1000000000}" 2>/dev/null || echo "0")
    local peak_cores=$(awk "BEGIN {printf \"%.1f\", $max_delta / 1000000000}" 2>/dev/null || echo "0")
    echo "  Build time: ${build_time}s, driver: ${mb} MB, peak mem: ${pmb} MB, avg CPU: ${avg_cores} cores, peak CPU: ${peak_cores} cores"

    local so_dir std_dir crates_measured
    so_dir=$(dirname "$so" 2>/dev/null)/deps
    std_dir="$build_dir/x86_64-unknown-linux-gnu/stage2/lib/rustlib/x86_64-unknown-linux-gnu/lib"
    crates_measured=0
    for rlib_dir in "$so_dir" "$std_dir"; do
        if [ -d "$rlib_dir" ]; then
            for rlib in "$rlib_dir"/*.rlib; do
                [ -f "$rlib" ] || continue
                local base crate text
                base=$(basename "$rlib" .rlib)
                crate=${base#lib}
                crate=${crate%-*}
                text=$(size --format=berkeley "$rlib" 2>/dev/null | tail -n +2 | awk '{sum += $1} END {print sum}')
                if [ -n "$text" ] && [ "$text" -gt 0 ]; then
                    echo "$level,$crate,$text" >> "${CRATES_LOG}-${level}"
                    crates_measured=$((crates_measured + 1))
                fi
            done
        fi
    done
    echo "  Measured $crates_measured crates"
}

# Merge per-level CSV files into the shared results/crates files
merge_csvs() {
    # Check if there's new per-level data to merge.  If all levels were
    # skipped (--skip-existing), preserve existing CSVs unchanged.
    local has_new=false
    for lvl in "${LEVELS[@]}"; do
        if [ -f "${RESULTS_LOG}-${lvl}" ] || [ -f "${CRATES_LOG}-${lvl}" ]; then
            has_new=true
            break
        fi
    done
    if [ "$has_new" = false ]; then
        # No new data to merge; preserve existing CSVs
        :
        return 0
    fi

    # Write headers (will be overwritten if main CSV doesn't exist yet)
    if [ ! -f "$RESULTS_LOG" ]; then
        echo "unix_ts,level,build_time_s,final_size,peak_mem_bytes,total_cpu_ns,peak_cpu_ns_per_sec" > "$RESULTS_LOG"
    fi
    if [ ! -f "$CRATES_LOG" ]; then
        echo "level,crate,text_size" > "$CRATES_LOG"
    fi

    local all_levels=("${LEVELS[@]}" "final")
    for lvl in "${all_levels[@]}"; do
        if [ -f "${RESULTS_LOG}-${lvl}" ]; then
            cat "${RESULTS_LOG}-${lvl}" >> "$RESULTS_LOG"
            rm "${RESULTS_LOG}-${lvl}"
        fi
        if [ -f "${CRATES_LOG}-${lvl}" ]; then
            cat "${CRATES_LOG}-${lvl}" >> "$CRATES_LOG"
            rm "${CRATES_LOG}-${lvl}"
        fi
    done
}

if [ "$EXISTING" = true ]; then
    # Per-crate CSV: one row per (level, crate) pair
    echo "level,crate,text_size" > "$CRATES_LOG"
    infer_from_existing || exit 1
elif [ -n "$REBUILD_DIR" ]; then
    # ---- Rebuild a single level dir (--rebuild-dir) ----
    # Preserve existing CSV rows, remove only rows for the rebuilt level
    echo "  Rebuilding only level \"$REBUILD_DIR\"..."
    if [ -f "$CRATES_LOG" ]; then
        grep -v "^${REBUILD_DIR}," "$CRATES_LOG" > "${CRATES_LOG}.tmp" && mv "${CRATES_LOG}.tmp" "$CRATES_LOG"
    fi
    if [ -f "$RESULTS_LOG" ]; then
        grep -v "^[0-9]*,${REBUILD_DIR}," "$RESULTS_LOG" > "${RESULTS_LOG}.tmp" 2>/dev/null || cp "$RESULTS_LOG" "${RESULTS_LOG}.tmp"
        mv "${RESULTS_LOG}.tmp" "$RESULTS_LOG"
    fi
    case "$REBUILD_DIR" in
        Oz)
            rm -rf "$BUILD_DIR"
            build_and_measure Oz "$BUILD_DIR"
            # Append new per-level entries to existing merged CSVs
            [ -f "${RESULTS_LOG}-Oz" ] && cat "${RESULTS_LOG}-Oz" >> "$RESULTS_LOG" && rm "${RESULTS_LOG}-Oz"
            [ -f "${CRATES_LOG}-Oz" ] && cat "${CRATES_LOG}-Oz" >> "$CRATES_LOG" && rm "${CRATES_LOG}-Oz"
            ;;
        final)
            rm -rf "${BUILD_DIR}-final"
            ;;
        *)
            rm -rf "${BUILD_DIR}-${REBUILD_DIR}"
            build_and_measure "$REBUILD_DIR" "${BUILD_DIR}-${REBUILD_DIR}"
            [ -f "${RESULTS_LOG}-${REBUILD_DIR}" ] && cat "${RESULTS_LOG}-${REBUILD_DIR}" >> "$RESULTS_LOG" && rm "${RESULTS_LOG}-${REBUILD_DIR}"
            [ -f "${CRATES_LOG}-${REBUILD_DIR}" ] && cat "${CRATES_LOG}-${REBUILD_DIR}" >> "$CRATES_LOG" && rm "${CRATES_LOG}-${REBUILD_DIR}"
            ;;
    esac
else
    # ---- Separate build directories mode (default) ----
    # Each level builds in its own cp -al'd copy of a clean template.
    # TEMPLATE_DIR is a read-only source for hard-link cloning — it is
    # never built in.  All level builds (Oz, Os, O1, O2, O3) run in
    # parallel from their own cloned directories.
    TEMPLATE_DIR="$ROOT/.brute-quick-template"

    # Create or refresh the clean template (from PGSO baseline cache)
    if [ ! -d "$TEMPLATE_DIR/x86_64-unknown-linux-gnu/stage2" ]; then
        echo "  Creating clean template from build-stage2-pgso ..."
        rm -rf "$TEMPLATE_DIR"
        cp -alT "$ROOT/build-stage2-pgso" "$TEMPLATE_DIR"
    fi

    # Clone or refresh each level's build directory from the clean template.
    # We always refresh (delete + re-clone) so a previously-failed build
    # directory doesn't corrupt the next run.  Hard-link copies take <1s.
    LEVEL_DIRS=()
    count=0
    for level in Oz Os O1 O2 O3; do
        dest="${BUILD_DIR}-${level}"
        [ "$level" = "Oz" ] && dest="$BUILD_DIR"

        # Skip cloning entirely if --skip-existing and data exists
        if [ "$SKIP_EXISTING" = true ] && grep -q "^[0-9]*,$level," "$RESULTS_LOG" 2>/dev/null; then
            echo "  [SKIP] $level already has data in $RESULTS_LOG"
            continue
        fi

        # Refresh from template (delete + re-clone)
        echo "  Preparing $dest for $level build ..."
        rm -rf "$dest"
        cp -alT "$TEMPLATE_DIR" "$dest"
        # Break hard link on lock file so parallel builds don't share one
        if [ -f "$dest/lock" ]; then
            rm -f "$dest/lock"
            echo -n "$$" > "$dest/lock" 2>/dev/null || true
        fi
        LEVEL_DIRS+=("$level:$dest")

        if [ "$PARALLEL" = true ]; then
            build_and_measure "$level" "$dest" &
            count=$((count + 1))
        else
            build_and_measure "$level" "$dest"
        fi
    done

    if [ "$PARALLEL" = true ] && [ "$count" -gt 0 ]; then
        echo "  Waiting for $count parallel build(s)..."
        wait
        echo "  All parallel builds complete"
    fi

    # Merge per-level CSV files into shared files
    merge_csvs
fi

# ---- Size-tweak builds (--size-tweaks only) ----
# Each tweak uses the base level's optfile plus extra LLVM args.
# Clone from the base level's build dir.  Stale rlibs are cleaned first.
if [ "$SIZE_TWEAKS" = true ]; then
    for tn in "${SIZE_TWEAK_NAMES[@]}"; do
        base="${TWEAK_BASE[$tn]}"
        extra="${TWEAK_ARGS[$tn]}"
        dest="${BUILD_DIR}-${tn}"
        base_dir="${BUILD_DIR}-${base}"

        if [ "$SKIP_EXISTING" = true ]; then
            if grep -q "^[0-9]*,$tn," "$RESULTS_LOG" 2>/dev/null; then
                echo "  [SKIP] $tn already has data in $RESULTS_LOG"
                continue
            fi
        fi

        echo ""
        echo "=== Creating $dest (hard-linked from $base_dir) ==="
        if [ -d "$dest" ]; then
            rm -rf "$dest"
        fi
        if [ -d "$base_dir" ]; then
            cp -alT "$base_dir" "$dest"
            # Break hard link on lock file for parallel safety
            if [ -f "$dest/lock" ]; then
                rm -f "$dest/lock"
                echo -n "$$" > "$dest/lock" 2>/dev/null || true
            fi
        else
            echo "  ERROR: base dir $base_dir not found, skipping $tn"
            continue
        fi

        # Symlink the per-level CGU file so build_and_measure picks up the base
        rm -f "$PGO_DATA/cgu_opt_levels_all_${tn}.txt"
        ln -s "cgu_opt_levels_all_${base}.txt" "$PGO_DATA/cgu_opt_levels_all_${tn}.txt"

        extra_rustflags="$extra"
        if [ "$PARALLEL" = true ]; then
            build_and_measure "$tn" "$dest" &
        else
            build_and_measure "$tn" "$dest"
        fi
        extra_rustflags=""
    done

    # Wait for parallel tweak builds to complete
    if [ "$PARALLEL" = true ]; then
        wait
        echo "  All parallel tweak builds complete"
    fi

    # Append tweak CSVs to the shared files
    if [ -f "${CRATES_LOG}-${SIZE_TWEAK_NAMES[0]}" ]; then
        for tn in "${SIZE_TWEAK_NAMES[@]}"; do
            [ -f "${CRATES_LOG}-${tn}" ] && cat "${CRATES_LOG}-${tn}" >> "$CRATES_LOG" && rm "${CRATES_LOG}-${tn}"
        done
    fi
    if [ -f "${RESULTS_LOG}-${SIZE_TWEAK_NAMES[0]}" ]; then
        for tn in "${SIZE_TWEAK_NAMES[@]}"; do
            [ -f "${RESULTS_LOG}-${tn}" ] && cat "${RESULTS_LOG}-${tn}" >> "$RESULTS_LOG" && rm "${RESULTS_LOG}-${tn}"
        done
    fi
fi

# ---- Step 3: Summary table ----
echo ""
echo "========================================================================="
echo "  Build summary"
echo "========================================================================="
printf "%-6s %-8s %-10s %-9s %-9s %-9s\n" "Level" "Time" "Driver" "Mem" "Avg CPU" "Peak CPU"
printf "%-6s %-8s %-10s %-9s %-9s %-9s\n" "-----" "----" "-------" "-----" "-------" "--------"
while IFS=, read -r ts level bt fs pm tcpu pcpu; do
    [ "$level" = "level" ] && continue
    [ "$bt" -eq 0 ] && continue
    avg_cpu=$(awk "BEGIN {printf \"%.1f\", $tcpu / $bt / 1000000000}" 2>/dev/null || echo "?")
    peak_cpu=$(awk "BEGIN {printf \"%.1f\", $pcpu / 1000000000}" 2>/dev/null || echo "?")
    printf "%-6s %-5ds   %-5d MB   %-4d MB   %-5sc   %-5sc\n" \
        "$level" "$bt" "$((fs / 1048576))" "$((pm / 1048576))" "$avg_cpu" "$peak_cpu"
done < "$RESULTS_LOG"

# ---- Step 4: Select best opt-level per crate ----
echo ""
echo "========================================================================="
echo "  Step 4: Selecting best opt-level per crate"
echo "========================================================================="

# Build associative maps of text sizes per crate per level
# Use temp files for simplicity
declare -A SIZE_AT  # key = "level,crate" -> size

# Read per-crate CSV into associative array
while IFS=, read -r lvl crate size; do
    [ "$lvl" = "level" ] && continue
    SIZE_AT["$lvl,$crate"]=$size
done < "$CRATES_LOG"

# Read PGSO baseline levels
mapfile -t BASELINE_LINES < <(grep -v '^#' "$PGSO_BASELINE" | grep -v '^[[:space:]]*$')

echo "crate,pgso_level,best_level,pgso_text,best_text,delta" > "$SUMMARY_LOG"

cp "$PGSO_BASELINE" "$OPT_FILE_FINAL"
total_delta=0
crates_changed=0

for line in "${BASELINE_LINES[@]}"; do
    crate=$(echo "$line" | sed 's/ [^ ]*$//')
    pgso_level=$(echo "$line" | awk '{print $NF}')

    pgso_idx=${SPEED_RANK[$pgso_level]:--1}

    best_level="$pgso_level"
    best_size=${SIZE_AT["$pgso_level,$crate"]:-99999999}

    # Try higher levels (more speed-optimized).
    # Size-tweak levels (O2-no-unroll etc.) are informational only — they
    # are not valid per-crate opt levels in the cgu-opt-levels file format,
    # so we skip them here.  Their results appear in the summary table.
    for candidate in "${LEVELS[@]}"; do
        is_tweak "$candidate" && continue
        cand_idx=${SPEED_RANK[$candidate]:--1}
        [ "$cand_idx" -lt "$pgso_idx" ] && continue  # skip slower levels

        cand_size=${SIZE_AT["$candidate,$crate"]:-}
        if [ -z "$cand_size" ]; then
            continue  # no data for this level
        fi

        if [ "$cand_size" -lt "$best_size" ]; then
            best_size=$cand_size
            best_level=$candidate
        elif [ "$cand_size" -eq "$best_size" ]; then
            # Tie — keep more speed-optimized (higher level)
            best_idx=${SPEED_RANK[$best_level]:--1}
            [ "$cand_idx" -gt "$best_idx" ] && best_level=$candidate
        fi
    done

    pgso_text=${SIZE_AT["$pgso_level,$crate"]:-0}
    delta=$((best_size - pgso_text))
    total_delta=$((total_delta + delta))

    if [ "$best_level" != "$pgso_level" ]; then
        crates_changed=$((crates_changed + 1))
        # Update the final opt-level file
        esc=$(echo "$crate" | sed 's/[\/&]/\\&/g')
        sed -i "s/^${esc} .*/${crate} ${best_level}/" "$OPT_FILE_FINAL"
        echo "  $crate: $pgso_level -> $best_level (text: $pgso_text -> $best_size, delta=$delta)"
    fi

    echo "$crate,$pgso_level,$best_level,$pgso_text,$best_size,$delta" >> "$SUMMARY_LOG"
done

echo ""
echo "Total crates changed: $crates_changed"
echo "Total text size delta: $total_delta bytes ($((total_delta / 1024)) KB)"
echo "Best file: $OPT_FILE_FINAL"

# ---- Size-tweak comparison (--size-tweaks only) ----
if [ "$SIZE_TWEAKS" = true ]; then
    echo ""
    echo "========================================================================="
    echo "  Size-tweak comparison (vs plain O2/O3 baseline)"
    echo "========================================================================="
    echo ""
    printf "%-28s %-8s %-8s %-8s\n" "Crate" "Base" "Best" "Delta"
    printf "%-28s %-8s %-8s %-8s\n" "-----" "----" "----" "-----"
    
    # For each baseline crate, compare the plain O2/O3 size vs each tweak
    # that shares that base level.
    declare -A DELTA_SHOWN
    for line in "${BASELINE_LINES[@]}"; do
        crate=$(echo "$line" | sed 's/ [^ ]*$//')
        pgso_level=$(echo "$line" | awk '{print $NF}')
        
        # Only consider crates whose PGSO level is O2 or O3
        case "$pgso_level" in O2|O3) ;; *) continue ;; esac
        
        base_size=${SIZE_AT["$pgso_level,$crate"]:-0}
        if [ "$base_size" -eq 0 ]; then continue; fi
        
        # Check each tweak that shares this base level
        for tn in "${SIZE_TWEAK_NAMES[@]}"; do
            base="${TWEAK_BASE[$tn]}"
            [ "$base" != "$pgso_level" ] && continue
            
            tsize=${SIZE_AT["$tn,$crate"]:-0}
            if [ "$tsize" -eq 0 ]; then continue; fi
            
            delta=$((tsize - base_size))
            if [ "$delta" -lt 0 ]; then
                key="$crate,$tn"
                if [ -z "${DELTA_SHOWN[$key]:-}" ]; then
                    printf "%-28s %-8s %-8s %-8s\n" "$crate" "$pgso_level" "$tn" "$delta"
                    DELTA_SHOWN["$key"]=1
                fi
            fi
        done
    done
    echo ""
    echo "  (only crates that got smaller under a tweak are shown)"
fi

# ---- Step 5: Build final binary ----
echo ""
echo "========================================================================="
echo "  Step 5: Building final binary with selected opt levels"
echo "========================================================================="

final_dest="${BUILD_DIR}-final"
if [ ! -d "$final_dest" ]; then
    if [ -d "$BUILD_DIR" ]; then
        echo "  Creating $final_dest (hard-linked from $BUILD_DIR)"
        cp -alT "$BUILD_DIR" "$final_dest"
    else
        echo "  WARNING: $BUILD_DIR not found, building from scratch"
    fi
fi

# Clean stale rlibs so the final build doesn't accumulate garbage
clean_count=0
for d in "$final_dest"/x86_64-unknown-linux-gnu/stage2-rustc/*/release/deps          "$final_dest"/x86_64-unknown-linux-gnu/stage2-rustc/release/deps          "$final_dest"/x86_64-unknown-linux-gnu/stage2/lib/rustlib/*/lib; do
    if [ -d "$d" ]; then
        n=$(find "$d" -name "*.rlib" 2>/dev/null | wc -l)
        find "$d" -name "*.rlib" -exec rm {} + 2>/dev/null || true
        clean_count=$((clean_count + n))
    fi
done
[ "$clean_count" -gt 0 ] && echo "  Cleaned $clean_count stale rlib(s)"


logfile="$BUILD_LOG_DIR/build-final.log"
peakfile="/tmp/brute-peak-final.txt"
cpufile="/tmp/brute-cpu-final"

start_ts=$(date +%s)
systemctl stop "brute-quick-final.scope" 2>/dev/null || true
systemd-run --scope --unit="brute-quick-final" \
    bash -c "
        cd '$ROOT'
        RUSTFLAGS_NOT_BOOTSTRAP='-Z human-readable-cgu-names -Z hot-cold-split \
            -Z cgu-opt-levels=$OPT_FILE_FINAL \
            -Z fn-opt-levels=$FN_FILE -Z fn-opt-level-default=Oz' \
        python3 x.py build --stage 2 compiler/rustc library/std \
            --build-dir '$final_dest' -j '${PARALLEL_JOBS}' > '$logfile' 2>&1
        rc=\$?
        echo -n \$(cat /sys/fs/cgroup/memory/system.slice/brute-quick-final.scope/memory.max_usage_in_bytes 2>/dev/null || echo 0) > '$peakfile'
        exit \$rc
    " &
build_pid=$!

# Poll CPU stats during final build
cpu_path="/sys/fs/cgroup/cpuacct/system.slice/brute-quick-final.scope/cpuacct.usage"
cpu_start=0
i=0
while [ ! -f "$cpu_path" ] && [ $i -lt 50 ]; do
    sleep 0.1; i=$((i + 1))
done
[ -f "$cpu_path" ] && cpu_start=$(cat "$cpu_path")

prev=$cpu_start; max_delta=0
while kill -0 "$build_pid" 2>/dev/null; do
    sleep 1
    if [ -f "$cpu_path" ]; then
        cur=$(cat "$cpu_path" 2>/dev/null || echo "$prev")
        delta=$((cur - prev))
        [ "$delta" -gt "$max_delta" ] && max_delta=$delta
        prev=$cur
    fi
done
wait "$build_pid" 2>/dev/null || true
end_ts=$(date +%s)

cpu_end=$cpu_start
[ -f "$cpu_path" ] && cpu_end=$(cat "$cpu_path" 2>/dev/null || echo "$cpu_end")
total_cpu_ns=$((cpu_end - cpu_start))
build_time=$((end_ts - start_ts))

so=$(find "$final_dest" -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' | head -1)
if [ -n "$so" ] && [ -f "$so" ]; then
    final_size=$(stat -c%s "$so")
    peak_mem=$(cat "$peakfile" 2>/dev/null || echo 0)
    rm -f "$peakfile"
    avg_cpu=$(awk "BEGIN {printf \"%.1f\", $total_cpu_ns / $build_time / 1000000000}" 2>/dev/null || echo "?")
    peak_cpu=$(awk "BEGIN {printf \"%.1f\", $max_delta / 1000000000}" 2>/dev/null || echo "?")
    echo "  Build time: ${build_time}s"
    echo "  Final librustc_driver.so: $final_size bytes ($((final_size / 1048576)) MB)"
    echo "  Peak memory: $peak_mem bytes ($((peak_mem / 1048576)) MB)"
    echo "  Avg CPU: ${avg_cpu} cores, peak CPU: ${peak_cpu} cores"
else
    echo "  ERROR: final build failed (see $logfile)" >&2
    tail -10 "$logfile"
fi

echo ""
echo "========================================================================="
echo "  Done!"
echo "  Results: $RESULTS_LOG"
echo "  Per-crate sizes: $CRATES_LOG"
echo "  Per-crate summary: $SUMMARY_LOG"
echo "  Best opt levels: $OPT_FILE_FINAL"
echo "  Build dirs left for inspection:"
echo "    $BUILD_DIR (Oz)"
for _level in "${LEVELS[@]:1}"; do
    [ -d "${BUILD_DIR}-${_level}" ] && echo "    ${BUILD_DIR}-${_level} ($_level)"
done
[ -d "${BUILD_DIR}-final" ] && echo "    ${BUILD_DIR}-final (final)"
echo "========================================================================="
