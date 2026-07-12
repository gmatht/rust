#!/usr/bin/env bash
# Brute-force CGU opt-level optimizer (LTO=thin variant).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGO_DATA="$ROOT/build/pgo_data/thin"
BUILD_DIR="$ROOT/build-brute-thin"
JOBS=4
CONFIG="config-thin.toml"

OPT_FILE_BEST="$PGO_DATA/cgu_opt_levels_thin.txt"
OPT_FILE_WORK="$PGO_DATA/cgu_opt_levels_thin_work.txt"
FN_FILE="$ROOT/build/pgo_data/fn_opt_levels_1x.txt"
RESULTS_LOG="$PGO_DATA/thin-results.csv"
STATE_FILE="$PGO_DATA/thin-state.txt"
BUILD_LOG_DIR="/tmp/brute-logs-thin"
mkdir -p "$BUILD_LOG_DIR"

mkdir -p "$PGO_DATA"
cd "$ROOT"

echo "========================================================================="
echo "  Brute-force CGU Opt-Level Optimizer (LTO=thin)"
echo "========================================================================="
echo "ROOT: $ROOT"
echo "BUILD_DIR: $BUILD_DIR"
echo "CONFIG: $CONFIG"
echo "JOBS: $JOBS"
echo ""

# Seed from PGSO baseline
if [ ! -f "$OPT_FILE_BEST" ]; then
    cp "$PGO_DATA/cgu_opt_levels_thin.txt" "$OPT_FILE_BEST"
    echo "Seeded from cgu_opt_levels_thin.txt"
fi

if [ ! -f "$RESULTS_LOG" ]; then
    echo "unix_ts,entry_idx,crate,old_opt,new_opt,build_time_s,rlib_size,final_size,sha256" > "$RESULTS_LOG"
fi

# ---- Helpers ----

so_path() {
    echo "$BUILD_DIR/x86_64-unknown-linux-gnu/stage2-rustc/x86_64-unknown-linux-gnu/release/librustc_driver.so"
}

find_rlibs() {
    local crate="$1"
    find "$BUILD_DIR/x86_64-unknown-linux-gnu/stage2-rustc" -name "lib${crate}-*.rlib" 2>/dev/null
}

find_src() {
    local crate="$1"
    for p in "$ROOT/compiler/$crate/src/lib.rs" "$ROOT/compiler/$crate/src/main.rs" \
             "$ROOT/library/$crate/src/lib.rs" "$ROOT/library/$crate/src/main.rs"; do
        [ -f "$p" ] && echo "$p" && return
    done
    return 1
}

force_rebuild() {
    local crate="$1"
    local src
    src=$(find_src "$crate" 2>/dev/null) || true
    if [ -n "$src" ]; then
        touch "$src"
        echo "  Touched $src"
    else
        local count=0
        while IFS= read -r f; do rm -f "$f"; count=$((count+1)); done < <(find_rlibs "$crate")
        echo "  Deleted $count rlib(s) for $crate"
    fi
}

do_build() {
    local optfile="$1"
    local extra="$2"
    local logfile="$BUILD_LOG_DIR/$(basename $optfile .txt)-$(date +%s).log"
    echo "  Building... (log: $logfile)"
    export CARGO_INCREMENTAL=1
    local rc
    RUSTFLAGS_NOT_BOOTSTRAP="-Z human-readable-cgu-names -Z hot-cold-split \
      -Z cgu-opt-levels=$optfile \
      -Z fn-opt-levels=$FN_FILE -Z fn-opt-level-default=Oz" \
        python3 x.py build --stage 2 $extra \
        --build-dir "$BUILD_DIR" -j "$JOBS" --config "$CONFIG" \
        --set rust.lto='off' > "$logfile" 2>&1 && rc=0 || rc=$?
    tail -3 "$logfile"
    if [ "$rc" -ne 0 ]; then
        echo "  ERROR: build exited with code $rc (see $logfile)" >&2
        grep -i "^error:" "$logfile" | head -5
        return 1
    fi
    if ! grep -q "Build completed successfully\|Finished.*\[optimized\]" "$logfile"; then
        echo "  ERROR: build may have failed (no success message)" >&2
        tail -15 "$logfile"
        return 1
    fi
    return 0
}

measure_final() {
    local so; so=$(so_path)
    [ -f "$so" ] && stat -c%s "$so" 2>/dev/null || echo 0
}

sha256_final() {
    local so; so=$(so_path)
    if [ -f "$so" ]; then
        sha256sum "$so" | cut -d' ' -f1
    else
        echo "N/A"
    fi
}

measure_rlib() {
    local crate="$1" total=0
    while IFS= read -r f; do
        s=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total=$((total + s))
    done < <(find_rlibs "$crate")
    echo "$total"
}

log_result() {
    local sha; sha=$(sha256_final)
    echo "$1,$2,$3,$4,$5,$6,$7,$8,$sha" >> "$RESULTS_LOG"
    echo "  LOG: $3 $4->$5: rlib=$7 final=$8 sha=$sha (${6}s)"
}

# ---- Main loop ----

mapfile -t LINES < <(grep -v '^#' "$OPT_FILE_BEST" | grep -v '^[[:space:]]*$')
TOTAL=${#LINES[@]}
echo "Total entries: $TOTAL"
echo ""

RESUME=0
[ -f "$STATE_FILE" ] && RESUME=$(cat "$STATE_FILE") && echo "Resuming from entry $RESUME"

# Build baseline to establish initial size
echo "=== Building baseline (PGSO default) ==="
do_build "$OPT_FILE_BEST" "compiler/rustc"
BASELINE_SIZE=$(measure_final)
echo "Baseline size: $BASELINE_SIZE bytes ($((BASELINE_SIZE / 1048576)) MB)"
[ "$BASELINE_SIZE" = "0" ] && { echo "ERROR: baseline build failed" >&2; exit 1; }

for ((i = RESUME; i < TOTAL; i++)); do
    line="${LINES[$i]}"
    crate=$(echo "$line" | sed 's/ [^ ]*$//')
    current_opt=$(echo "$line" | awk '{print $NF}')

    best_for_entry=$BASELINE_SIZE
    best_for_entry_opt=$current_opt

    if [ "$current_opt" = "O3" ]; then
        echo "[$((i+1))/$TOTAL] $crate already at O3, skipping"
        echo "$((i+1))" > "$STATE_FILE"
        continue
    fi

    case "$current_opt" in
        Oz) candidates=("Os" "O2" "O3") ;;
        Os) candidates=("O2" "O3") ;;
        O2) candidates=("O3") ;;
        *) echo "Unknown opt: $current_opt"; echo "$((i+1))" > "$STATE_FILE"; continue ;;
    esac

    echo ""
    echo "========================================================================"
    echo "[$((i+1))/$TOTAL] $crate (currently $current_opt)"
    echo "========================================================================="

    for new_opt in "${candidates[@]}"; do
        cp "$OPT_FILE_BEST" "$OPT_FILE_WORK"
        esc=$(echo "$crate" | sed 's/[\/&]/\\&/g')
        sed -i "s/^${esc} .*/${crate} ${new_opt}/" "$OPT_FILE_WORK"

        echo ""
        echo "--- Trying $crate: $current_opt -> $new_opt ---"

        force_rebuild "$crate"

        start_ts=$(date +%s)
        if ! do_build "$OPT_FILE_WORK" "compiler/rustc"; then
            echo "  Build failed, skipping"
            continue
        fi
        end_ts=$(date +%s)
        build_time=$((end_ts - start_ts))

        rlib_size=$(measure_rlib "$crate")
        final_size=$(measure_final)

        log_result "$end_ts" "$((i+1))" "$crate" "$current_opt" "$new_opt" \
            "$build_time" "$rlib_size" "$final_size"

        if [ "$final_size" -lt "$best_for_entry" ] && [ "$final_size" -ne 0 ]; then
            old_best=$best_for_entry
            best_for_entry=$final_size
            best_for_entry_opt=$new_opt
            BASELINE_SIZE=$final_size
            cp "$OPT_FILE_WORK" "$OPT_FILE_BEST"
            echo "  NEW BEST: $crate $new_opt (final $final_size, was $old_best)"
        elif [ "$final_size" -eq "$best_for_entry" ] && [ "$final_size" -ne 0 ]; then
            order_old=$(printf "%s\n" "Oz" "Os" "O2" "O3" | grep -n "$best_for_entry_opt" | cut -d: -f1)
            order_new=$(printf "%s\n" "Oz" "Os" "O2" "O3" | grep -n "$new_opt" | cut -d: -f1)
            if [ "$order_new" -gt "$order_old" ]; then
                best_for_entry=$final_size
                best_for_entry_opt=$new_opt
                cp "$OPT_FILE_WORK" "$OPT_FILE_BEST"
                echo "  TIE -> KEEP: $crate $new_opt (same final size $final_size, more speed)"
            else
                echo "  TIE -> SKIP: $crate $new_opt (same size, not more speed-optimized)"
            fi
        else
            echo "  SKIP: $crate $new_opt (final $final_size > best $best_for_entry)"
        fi
    done

    echo "$((i+1))" > "$STATE_FILE"
done

echo ""
echo "=== Building final binary with full library/std ==="
cp "$OPT_FILE_BEST" "$OPT_FILE_WORK"
force_rebuild "$(head -1 "$OPT_FILE_BEST" | awk '{print $1}')"
logfile="$BUILD_LOG_DIR/final-$(date +%s).log"
echo "  Building... (log: $logfile)"
RUSTFLAGS_NOT_BOOTSTRAP="-Z human-readable-cgu-names -Z hot-cold-split \
  -Z cgu-opt-levels=$OPT_FILE_WORK \
  -Z fn-opt-levels=$FN_FILE -Z fn-opt-level-default=Oz" \
  python3 x.py build --stage 2 compiler/rustc library/std \
  --build-dir "$BUILD_DIR" -j "$JOBS" --config "$CONFIG" \
  > "$logfile" 2>&1 || {
    echo "  ERROR: final build failed" >&2; tail -5 "$logfile"
  }

so=$(so_path)
if [ -f "$so" ]; then
    final=$(stat -c%s "$so")
    echo "  FINAL librustc_driver.so: $final bytes ($((final / 1048576)) MB)"
fi

rm -f "$OPT_FILE_WORK" "$STATE_FILE"
echo ""
echo "========================================================================="
echo "  Done! Best file: $OPT_FILE_BEST"
echo "  Results: $RESULTS_LOG"
echo "========================================================================="