#!/usr/bin/env bash
# Brute-force combination explorer.
# Reuses existing per-level measurements from brute-opt-quick, then builds
# and measures several hybrid strategies (combinations of CGU opt levels,
# per-function opt levels, hot-cold-split, LTO mode, etc.)
#
# Usage:
#   ./scripts/brute-opt-combos.sh                     # build all strategies
#   ./scripts/brute-opt-combos.sh --strategies 1,3,7  # build specific strategies by index
#   ./scripts/brute-opt-combos.sh --strategies brute-quick-nofn,all-o3-nofn  # by name
#   ./scripts/brute-opt-combos.sh --rebuild            # force rebuild even if binary exists
#   ./scripts/brute-opt-combos.sh --list               # just list strategies and exit
#   ./scripts/brute-opt-combos.sh --parallel 2         # build up to N in parallel
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGO_DATA="$ROOT/build/pgo_data"
BUILD_DIR="$ROOT/build-brute-quick"         # Oz template (has LLVM/bootstrap cached)
JOBS=4
PARALLEL=1

FN_FILE="$PGO_DATA/fn_opt_levels_1x.txt"
PGSO_BASELINE="$PGO_DATA/cgu_opt_levels_1x.txt"
BRUTE_QUICK_OPT="$PGO_DATA/cgu_opt_levels_brute_quick.txt"
RESULTS_LOG="$PGO_DATA/combo-results.csv"
BUILD_LOG_DIR="/tmp/brute-combo-logs"
mkdir -p "$BUILD_LOG_DIR"

cd "$ROOT"

# ---- Parse args ----
REBUILD=false
LIST_ONLY=false
SELECTED_STRATEGIES=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --strategies) SELECTED_STRATEGIES="$2"; shift 2 ;;
        --rebuild) REBUILD=true; shift ;;
        --list) LIST_ONLY=true; shift ;;
        --parallel) PARALLEL="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# ---- Define strategies ----
# Format: name:cgu_src:fn_mode:hcs_mode:lto_mode:extra_desc
#   cgu_src:  "1x" = PGSO baseline file
#             "brute" = brute-quick result file
#             "all-O3" = generate all crates at O3
#             "all-Oz" = generate all crates at Oz
#             "hot-O3-cold-Oz" = keep PGSO O3/O2 crates, drop Oz/Os to Oz
#   fn_mode:  "fn-on" = use -Z fn-opt-levels=$FN_FILE
#             "fn-off" = no fn-opt-levels flag
#   hcs_mode: "hcs-on" = pass -Z hot-cold-split
#             "hcs-off" = no hot-cold-split
#   lto_mode: "fat" = default (config.toml has lto=fat)
#             "thin" = --config config-thin.toml
#             "off"  = --set rust.lto=off

STRATEGIES=(
    "baseline-pgso:1x:fn-on:hcs-on:fat:Original PGSO baseline, all Oz CGU + hot fns O3"
    "brute-quick:brute:fn-on:hcs-on:fat:Brute-opt-quick selected CGU levels + fn attrs"
    "brute-quick-nofn:brute:fn-off:hcs-off:fat:Brute-quick CGU levels, no fn-attrs, no HCS"
    "brute-quick-nohcs:brute:fn-on:hcs-off:fat:Brute-quick CGU levels, fn-attrs, no HCS"
    "all-o3-nofn:all-O3:fn-off:hcs-off:fat:Pure O3 global, no fn-attrs, no HCS"
    "all-oz-warmfn:all-Oz:fn-on:hcs-on:fat:All Oz CGU + hot fns get O3 via fn-attrs"
    "hot-o3-cold-oz:hot-O3-cold-Oz:fn-on:hcs-on:fat:PGSO-hot O3, PGSO-cold Oz + fn-attrs"
    "brute-quick-hcs-only:brute:fn-off:hcs-on:fat:Brute-quick CGU, HCS only (no fn-attrs)"
    "all-o3-warmfn:all-O3:fn-on:hcs-on:fat:All O3 CGU + fn-attrs + HCS (O3 + cold fn Oz)"
    "brute-quick-lto-off:brute:fn-on:hcs-on:off:Brute-quick CGU + fn-attrs + HCS, LTO=off"
)

# ---- Build an index ----
declare -A STRAT_IDX
for i in "${!STRATEGIES[@]}"; do
    name="${STRATEGIES[$i]%%:*}"
    STRAT_IDX["$name"]=$i
done

# ---- --list ----
if [ "$LIST_ONLY" = true ]; then
    echo "Available strategies:"
    echo ""
    printf "  %-2s  %-28s  %s\n" "#" "Name" "Description"
    printf "  %-2s  %-28s  %s\n" "--" "----" "-----------"
    for i in "${!STRATEGIES[@]}"; do
        IFS=: read -r name cgu_src fn_mode hcs_mode lto_mode desc <<< "${STRATEGIES[$i]}"
        printf "  %-2d  %-28s  %s\n" "$i" "$name" "$desc"
    done
    exit 0
fi

# ---- Filter strategies ----
RUN_STRATEGIES=()
if [ -n "$SELECTED_STRATEGIES" ]; then
    IFS=',' read -ra selected <<< "$SELECTED_STRATEGIES"
    for sel in "${selected[@]}"; do
        if [[ "$sel" =~ ^[0-9]+$ ]]; then
            [ "$sel" -ge 0 ] && [ "$sel" -lt "${#STRATEGIES[@]}" ] || { echo "Invalid index: $sel"; exit 1; }
            RUN_STRATEGIES+=("${STRATEGIES[$sel]}")
        else
            [ -n "${STRAT_IDX[$sel]:-}" ] || { echo "Unknown strategy: $sel"; exit 1; }
            RUN_STRATEGIES+=("${STRATEGIES[${STRAT_IDX[$sel]}]}")
        fi
    done
else
    RUN_STRATEGIES=("${STRATEGIES[@]}")
fi

# ---- Helpers ----

# Generate a cgu_opt_levels file for a given source
gen_cgu_opt_levels() {
    local cgu_src="$1"
    local out_file="$2"
    rm -f "$out_file"
    case "$cgu_src" in
        1x)           cp "$PGSO_BASELINE" "$out_file" ;;
        brute)        cp "$BRUTE_QUICK_OPT" "$out_file" ;;
        all-O3)       sed 's/ [^ ]*$/ O3/' "$PGSO_BASELINE" > "$out_file" ;;
        all-Oz)       sed 's/ [^ ]*$/ Oz/' "$PGSO_BASELINE" > "$out_file" ;;
        hot-O3-cold-Oz)
            while IFS= read -r line; do
                if [ -z "$line" ] || [[ "$line" == \#* ]]; then
                    echo "$line" >> "$out_file"
                    continue
                fi
                crate=$(echo "$line" | sed 's/ [^ ]*$//')
                pgso_opt=$(echo "$line" | awk '{print $NF}')
                case "$pgso_opt" in
                    O3|O2) echo "$line" >> "$out_file" ;;
                    *)     echo "$crate Oz" >> "$out_file" ;;
                esac
            done < "$PGSO_BASELINE"
            ;;
        *) echo "ERROR: unknown cgu_src '$cgu_src'" >&2; return 1 ;;
    esac
}

# Build RUSTFLAGS_NOT_BOOTSTRAP string for a strategy
get_rustflags() {
    local cgu_file="$1" fn_mode="$2" hcs_mode="$3"
    local flags="-Z human-readable-cgu-names -Z cgu-opt-levels=$cgu_file"
    [ "$fn_mode" = "fn-on" ] && flags="$flags -Z fn-opt-levels=$FN_FILE -Z fn-opt-level-default=Oz"
    [ "$hcs_mode" = "hcs-on" ] && flags="$flags -Z hot-cold-split"
    echo "$flags"
}

# ---- Globals for build_strategy results ----
BUILD_RESULT_SIZE=0
BUILD_RESULT_TIME=0
BUILD_RESULT_PEAK=0
BUILD_RESULT_CRATES=0

# ---- Build a single strategy ----
build_strategy() {
    local name="$1" cgu_src="$2" fn_mode="$3" hcs_mode="$4" lto_mode="$5" desc="$6"

    local build_dir="$ROOT/build-combo-$name"
    local cgu_file="$PGO_DATA/cgu_opt_levels_combo_$name.txt"
    local logfile="$BUILD_LOG_DIR/build-$name.log"
    local peakfile="/tmp/brute-combo-peak-$name.txt"

    # Reset globals
    BUILD_RESULT_SIZE=0; BUILD_RESULT_TIME=0; BUILD_RESULT_PEAK=0; BUILD_RESULT_CRATES=0

    # Generate CGU opt levels file
    gen_cgu_opt_levels "$cgu_src" "$cgu_file"

    # Check for cached binary (also check canonical locations)
    local cached_dirs=()
    cached_dirs+=("$build_dir")
    case "$name" in
        baseline-pgso) cached_dirs+=("$ROOT/build-stage2-pgso") ;;
        brute-quick)   cached_dirs+=("$ROOT/build-brute-quick-final") ;;
    esac
    local so=""
    for cd in "${cached_dirs[@]}"; do
        if [ -d "$cd" ]; then
            so=$(find "$cd" -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' 2>/dev/null | head -1) || true
            if [ -n "$so" ]; then break; fi
        fi
    done
    if [ -n "$so" ] && [ "$REBUILD" = false ]; then
        local existing_size
        existing_size=$(stat -c%s "$so" 2>/dev/null || echo 0)
        if [ "$existing_size" -gt 0 ]; then
            BUILD_RESULT_SIZE=$existing_size
            # If the found SO is not in our build_dir, symlink it so next run finds it fast
            if [[ "$so" != "$build_dir"* ]]; then
                mkdir -p "$build_dir"
                ln -sf "$so" "$build_dir/" 2>/dev/null || true
            fi
            echo "  [CACHED] $so ($existing_size bytes)"
            return 0
        fi
    fi

    # Clone template if needed
    if [ ! -d "$build_dir" ]; then
        echo "  Cloning from $BUILD_DIR (hard links)..."
        cp -alT "$BUILD_DIR" "$build_dir"
    fi

    local rustflags
    rustflags=$(get_rustflags "$cgu_file" "$fn_mode" "$hcs_mode")

    local lto_flag=""
    [ "$lto_mode" = "off" ] && lto_flag="--set rust.lto=off"
    [ "$lto_mode" = "thin" ] && lto_flag="--config $ROOT/config-thin.toml"

    local start_ts
    start_ts=$(date +%s)
    echo "  Building..."

    # Kill any stale scope
    systemctl stop "brute-combo-${name}.scope" 2>/dev/null || true

    systemd-run --scope --unit="brute-combo-${name}" \
        bash -c "
            cd '$ROOT'
            RUSTFLAGS_NOT_BOOTSTRAP='$rustflags' \
            python3 x.py build --stage 2 compiler/rustc library/std \
                $lto_flag --build-dir '$build_dir' -j '$JOBS' > '$logfile' 2>&1
            rc=\$?
            echo -n \$(cat /sys/fs/cgroup/memory/system.slice/brute-combo-${name}.scope/memory.max_usage_in_bytes 2>/dev/null || echo 0) > '$peakfile'
            exit \$rc
        " &
    local build_pid=$!

    # Poll CPU stats
    local cpu_path="/sys/fs/cgroup/cpuacct/system.slice/brute-combo-${name}.scope/cpuacct.usage"
    local cpu_start=0 i=0
    while [ ! -f "$cpu_path" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -f "$cpu_path" ] && cpu_start=$(cat "$cpu_path")

    local prev=$cpu_start max_delta=0
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
    local end_ts build_time
    end_ts=$(date +%s)
    build_time=$((end_ts - start_ts))
    BUILD_RESULT_TIME=$build_time

    local cpu_end=$cpu_start
    [ -f "$cpu_path" ] && cpu_end=$(cat "$cpu_path" 2>/dev/null || echo "$cpu_end")

    local peak_mem=0
    [ -f "$peakfile" ] && peak_mem=$(cat "$peakfile") && rm -f "$peakfile"
    BUILD_RESULT_PEAK=$peak_mem

    # Measure final binary
    so=$(find "$build_dir" -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' | head -1)
    if [ -n "$so" ] && [ -f "$so" ]; then
        BUILD_RESULT_SIZE=$(stat -c%s "$so")
    fi

    # Measure rlib text sizes (optional, for diagnostics)
    local rlib_dir crates_measured=0
    rlib_dir=$(dirname "$so" 2>/dev/null)/deps
    if [ -d "$rlib_dir" ]; then
        local crates_csv_tmp="/tmp/brute-combo-crates-${name}.csv"
        echo "strategy,crate,text_size" > "$crates_csv_tmp"
        for rlib in "$rlib_dir"/*.rlib; do
            [ -f "$rlib" ] || continue
            local base crate text
            base=$(basename "$rlib" .rlib)
            crate=${base#lib}; crate=${crate%-*}
            text=$(size --format=berkeley "$rlib" 2>/dev/null | tail -n +2 | awk '{sum += $1} END {print sum}')
            if [ -n "$text" ] && [ "$text" -gt 0 ]; then
                echo "$name,$crate,$text" >> "$crates_csv_tmp"
                crates_measured=$((crates_measured + 1))
            fi
        done
    fi
    BUILD_RESULT_CRATES=$crates_measured

    echo "  Build time: ${build_time}s, driver: ${BUILD_RESULT_SIZE} bytes ($((BUILD_RESULT_SIZE / 1048576)) MB), peak: $((peak_mem / 1048576)) MB, crates: $crates_measured"
}

# =====================================================================
#  Main
# =====================================================================

echo ""
echo "========================================================================="
echo "  Brute-force Combination Explorer"
echo "========================================================================="
echo "Root: $ROOT"
echo "Template: $BUILD_DIR"
echo "Strategies: ${#RUN_STRATEGIES[@]}"
echo "Parallel builds: $PARALLEL"
echo ""

# Pre-check
if [ ! -d "$BUILD_DIR/x86_64-unknown-linux-gnu/stage2-rustc" ]; then
    echo "ERROR: Template build directory $BUILD_DIR does not contain stage2 artifacts."
    echo "Run scripts/brute-opt-quick.sh first to establish the template."
    exit 1
fi

# Clear results log
echo "strategy,build_time_s,final_size_bytes,peak_mem_bytes,crates_measured,description" > "$RESULTS_LOG"

# Reference sizes for comparison table
declare -A REF
REF["brute-quick"]=$(find /root/src/rustloop/rust1.96/build-brute-quick-final -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' -exec stat -c%s {} + 2>/dev/null | head -1)
REF["baseline-pgso"]=$(find /root/src/rustloop/rust1.96/build-stage2-pgso -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' -exec stat -c%s {} + 2>/dev/null | head -1)
# Oz is the base build-brute-quick (no suffix)
REF["all-Oz"]=$(find /root/src/rustloop/rust1.96/build-brute-quick -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' -exec stat -c%s {} + 2>/dev/null | head -1)
for level in Os O1 O2 O3; do
    REF["all-${level}"]=$(find "/root/src/rustloop/rust1.96/build-brute-quick-${level}" -name 'librustc_driver.so' -path '*/stage2-rustc/*/release/*' -exec stat -c%s {} + 2>/dev/null | head -1)
done
true  # dummy

# Run strategies
declare -A RESULTS
for strat in "${RUN_STRATEGIES[@]}"; do
    IFS=: read -r name cgu_src fn_mode hcs_mode lto_mode desc <<< "$strat"

    echo ""
    echo "========================================================================"
    echo "  Strategy: $name"
    echo "  $desc"
    echo "  CGU: $cgu_src  |  fn: $fn_mode  |  HCS: $hcs_mode  |  LTO: $lto_mode"
    echo "========================================================================"

    build_strategy "$name" "$cgu_src" "$fn_mode" "$hcs_mode" "$lto_mode" "$desc"
    RESULTS["$name"]=$BUILD_RESULT_SIZE

    if [ "$BUILD_RESULT_SIZE" -gt 0 ]; then
        echo "  => ${BUILD_RESULT_SIZE} bytes ($((BUILD_RESULT_SIZE / 1048576)) MB)"
    else
        echo "  => BUILD FAILED (see $BUILD_LOG_DIR/build-$name.log)"
    fi

    echo "$name,${BUILD_RESULT_TIME},${BUILD_RESULT_SIZE},${BUILD_RESULT_PEAK},${BUILD_RESULT_CRATES},$desc" >> "$RESULTS_LOG"
done

# ---- Summary table ----
echo ""
echo "========================================================================="
echo "  Results"
echo "========================================================================="

# Find best size
BEST_SIZE=999999999
for s in "${RESULTS[@]}" "${REF[@]}"; do
    [ "$s" -gt 0 ] 2>/dev/null && [ "$s" -lt "$BEST_SIZE" ] && BEST_SIZE=$s
done

printf "%-30s %12s %5s %12s %12s\n" "Strategy" "Size (bytes)" "MB" "vs PGSO" "vs Best"
printf "%-30s %12s %5s %12s %12s\n" "-------" "-----------" "---" "-------" "-------"

print_row() {
    local name="$1" size="$2"
    [ "$size" -eq 0 ] 2>/dev/null && return
    local vs_pgso=$((size - REF["baseline-pgso"]))
    local vs_best=$((size - BEST_SIZE))
    local vs_pgso_str vs_best_str
    if [ "$vs_pgso" -lt 0 ]; then
        vs_pgso_str="-$(( -vs_pgso )) B"
    elif [ "$vs_pgso" -gt 0 ]; then
        vs_pgso_str="+$(( vs_pgso )) B"
    else
        vs_pgso_str="same"
    fi
    if [ "$vs_best" -lt 0 ]; then
        vs_best_str="-$(( -vs_best )) B"
    elif [ "$vs_best" -gt 0 ]; then
        vs_best_str="+$(( vs_best )) B"
    else
        vs_best_str="same"
    fi
    printf "%-30s %12d %4dM %12s %12s\n" "$name" "$size" "$((size / 1048576))" "$vs_pgso_str" "$vs_best_str"
}

print_row "REF: brute-quick-final" "${REF["brute-quick"]}"
print_row "REF: baseline-pgso" "${REF["baseline-pgso"]}"
print_row "REF: all-Oz (LTO=off)" "${REF["all-Oz"]}"
print_row "REF: all-Os (LTO=off)" "${REF["all-Os"]}"
print_row "REF: all-O1 (LTO=off)" "${REF["all-O1"]}"
print_row "REF: all-O2 (LTO=off)" "${REF["all-O2"]}"
print_row "REF: all-O3 (LTO=off)" "${REF["all-O3"]}"

echo "  ---"
for strat in "${RUN_STRATEGIES[@]}"; do
    IFS=: read -r name cgu_src fn_mode hcs_mode lto_mode desc <<< "$strat"
    print_row "$name" "${RESULTS[$name]:-0}"
done

echo ""
echo "Results saved to: $RESULTS_LOG"
echo "Build logs: $BUILD_LOG_DIR"
echo "========================================================================="
