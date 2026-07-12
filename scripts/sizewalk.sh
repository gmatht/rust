#!/usr/bin/env bash
# sizewalk.sh — Walk through stage2 compiler sizes, measuring resources.
#
# 7 considerations addressed inline (see tags [1]–[7]).
#
# Builds the stage2 rustc in 6 incremental configurations:
#   1. Default (stock Cargo, no size opts)
#   2. Standard size opts (lto=fat, cgu=1)
#   3. CGU-PGSO  (per-CGU opt levels)
#   4. CGU + fn PGSO (both per-CGU and per-function opt levels)
#   5. Brute-opt-quick refined (optimised CGU levels from brute-opt-quick.sh)
#   6. Function-level PGSO only (no CGU overrides)
#
# Each step measures:
#   - rustc_driver.so size
#   - Wall clock build time
#   - Average and max CPU utilisation (cores, from cpu.stat/usage_usec)
#   - Peak and average memory usage (via cgroup v1 memory controller)
#
# Uses systemd-run for cgroup isolation (like brute-opt-quick.sh).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${JOBS:-4}"
RESULTS_LOG="$ROOT/sizewalk-results.csv"
BUILD_LOG_DIR="/tmp/sizewalk-logs"
PGO_DATA="$ROOT/build/pgo_data"

CGU_FILE_1X="$PGO_DATA/cgu_opt_levels_1x.txt"
FN_FILE_1X="$PGO_DATA/fn_opt_levels_1x.txt"
CGU_BRUTE_QUICK="$PGO_DATA/cgu_opt_levels_brute_quick.txt"

mkdir -p "$BUILD_LOG_DIR"

# ---------------------------------------------------------------------------
# [6] Stage1 sanity helpers
# ---------------------------------------------------------------------------
STAGE1_RUSTC="$ROOT/build/x86_64-unknown-linux-gnu/stage2/bin/rustc"

check_stage1() {
    echo ""
    echo "========================================================================="
    echo "  Step 0: Sanity checking stage1 compiler"
    echo "========================================================================="

    if [ -x "$STAGE1_RUSTC" ]; then
        echo "  Found: $STAGE1_RUSTC"
    else
        echo "  Not found — building stage1 first ..."
        python3 "$ROOT/x.py" build --stage 1 library/std compiler/rustc \
            --build-dir "$ROOT/build" -j "$JOBS" 2>&1 | tail -5
        echo "  Stage1 build complete."
    fi

    echo -n "  Smoke test: "
    if "$STAGE1_RUSTC" --version > /dev/null 2>&1; then
        echo "OK ($("$STAGE1_RUSTC" --version 2>/dev/null))"
    else
        echo "FAILED"
        exit 1
    fi
    echo "  Stage1 is sane."
}

# ---------------------------------------------------------------------------
# .cargo/config.toml save/restore (needed for step 1: pure stock defaults)
# ---------------------------------------------------------------------------
save_cargo_config() {
    if [ -f "$ROOT/.cargo/config.toml" ]; then
        mv "$ROOT/.cargo/config.toml" "$ROOT/.cargo/config.toml.sizewalk-saved"
        echo "  Disabled .cargo/config.toml"
    fi
}
restore_cargo_config() {
    if [ -f "$ROOT/.cargo/config.toml.sizewalk-saved" ]; then
        mv "$ROOT/.cargo/config.toml.sizewalk-saved" "$ROOT/.cargo/config.toml"
        echo "  Restored .cargo/config.toml"
    fi
}
cleanup() { restore_cargo_config; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Find librustc_driver.so in a build tree
# ---------------------------------------------------------------------------
find_so() {
    local build_dir="$1"
    find "$build_dir" -name 'librustc_driver.so' \
        -path '*/stage2-rustc/*/release/*' 2>/dev/null | head -1
}

# Create a stripped copy of librustc_driver.so and return its size.
# Uses 'strip --strip-debug' to remove debug symbols without breaking
# backtraces.  The original .so is never modified.
measure_stripped_so() {
    local build_dir="$1"
    local so
    so=$(find_so "$build_dir")
    if [ -z "$so" ] || [ ! -f "$so" ]; then
        echo 0
        return
    fi
    local stripped="${so}.stripped"
    cp "$so" "$stripped"
    strip --strip-debug "$stripped" 2>/dev/null || true
    stat -c%s "$stripped" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Core: build under systemd-run, poll cgroups, log results.
#
# Usage:  build_and_measure <step> <label> <build-dir> <base-dir> \
#                            "<rustflags>" [<extra-xpy-args>...]
#
#   <step>     – integer step number (1-6)
#   <label>    – human-readable label
#   <build-dir> – where to build (will be rm -rf'd first)
#   <base-dir>  – existing tree to hard-link from, or "" for fresh
#   <rustflags> – value for RUSTFLAGS_NOT_BOOTSTRAP (empty string ok)
#   <extra-xpy-args> – any additional flags passed to x.py (optional)
#
# [1] Build dir reuse: Each step gets a fresh rm -rf'd directory.
# [2] Hard linking: cp -alT from <base-dir> preserves unchanged artifacts.
# [3] Job count: $JOBS env var (default 4).
# [4] Dependency download: only step 1 downloads LLVM; steps 2-6 reuse.
# [5] Error handling: on failure, status=FAIL is logged and script continues.
# [7] CPU core calculation: avg = total_cpu_usec / (wall_s * 1e6),
#                            peak = max_delta_usec / 1e6.
# ---------------------------------------------------------------------------
build_and_measure() {
    local step="$1"
    local label="$2"
    local build_dir="$3"
    local base_dir="$4"
    local rustflags="$5"
    shift 5
    local extra_args=("$@")

    local unit="sizewalk-${step}"
    local logfile="$BUILD_LOG_DIR/build-${step}.log"
    local peakfile="/tmp/sizewalk-peak-${step}.txt"

    echo ""
    echo "========================================================================"
    echo "  Step ${step}: ${label}"
    echo "  Build dir: ${build_dir}"
    echo "  Unit:      ${unit}.scope"
    echo "========================================================================"

    # [1] Fresh build dir
    rm -rf "$build_dir"

    # [2] Hard-link from base if available (preserves LLVM, libstd, etc.)
    if [ -n "$base_dir" ] && [ -d "$base_dir" ]; then
        echo "  Hard-linking from ${base_dir} ..."
        cp -alT "$base_dir" "$build_dir"
        echo "  Done."
    fi

    local start_ts
    start_ts=$(date +%s)

    # ------------------------------------------------------------------
    # Construct the build command for systemd-run.
    #
    # We use printf %q to properly quote every component — this handles
    # spaces and special chars in RUSTFLAGS, paths, etc.
    #
    # The inner bash -c pipeline:
    #   1. cd to ROOT
    #   2. set RUSTFLAGS_NOT_BOOTSTRAP and run x.py build
    #   3. capture exit code
    #   4. snapshot peak memory from the cgroup
    #   5. exit with the build's exit code
    # ------------------------------------------------------------------
    local build_cmd
    printf -v build_cmd 'cd %q && RUSTFLAGS_NOT_BOOTSTRAP=%q python3 x.py build --stage 2 compiler/rustc library/std --build-dir %q -j %d %s >%q 2>&1; rc=$?; echo -n $(cat /sys/fs/cgroup/memory/system.slice/%s.scope/memory.max_usage_in_bytes 2>/dev/null || echo 0) >%q; exit $rc' \
        "$ROOT" \
        "$rustflags" \
        "$build_dir" \
        "$JOBS" \
        "${extra_args[*]}" \
        "$logfile" \
        "$unit" \
        "$peakfile"

    # ------------------------------------------------------------------
    # Launch systemd-run in background so we can poll cgroup files.
    #
    # Memory cgroup:
    #   /sys/fs/cgroup/memory/system.slice/<unit>.scope/
    #     memory.max_usage_in_bytes  (peak, read after build)
    #     memory.usage_in_bytes      (live, polled for average)
    #
    # CPU cgroup:
    #   /sys/fs/cgroup/cpu/system.slice/<unit>.scope/cpu.stat
    #     usage_usec                 (total CPU time in microseconds)
    #
    # The cpuacct controller is on a legacy hierarchy here, so we read
    # from the cpu controller which is under systemd hierarchy.
    # ------------------------------------------------------------------
    systemd-run --scope --unit="$unit" bash -c "$build_cmd" &
    local build_pid=$!

    # Paths (scope dirs exist only while the unit is alive)
    local cpu_path="/sys/fs/cgroup/cpu/system.slice/${unit}.scope/cpu.stat"
    local mem_path="/sys/fs/cgroup/memory/system.slice/${unit}.scope/memory.usage_in_bytes"

    local cpu_start_usec=0
    local mem_samples=()   # each element: "unix_ts,bytes"

    # Wait for cgroup directories to appear (up to 5 s)
    local i=0
    while [ ! -f "$cpu_path" ] && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    # Initial CPU reading
    if [ -f "$cpu_path" ]; then
        cpu_start_usec=$(grep '^usage_usec ' "$cpu_path" 2>/dev/null | awk '{print $2}' || echo 0)
    fi
    local prev=$cpu_start_usec
    local max_delta=0

    # Poll loop — runs every second while the build is alive
    while kill -0 "$build_pid" 2>/dev/null; do
        sleep 1

        # [7] CPU: per-second usage_usec delta → peak cores
        if [ -f "$cpu_path" ]; then
            local cur
            cur=$(grep '^usage_usec ' "$cpu_path" 2>/dev/null | awk '{print $2}' || echo "$prev")
            local delta=$((cur - prev))
            [ "$delta" -gt "$max_delta" ] && max_delta=$delta
            prev=$cur
        fi

        # Memory: sample current usage for average
        if [ -f "$mem_path" ]; then
            local now
            now=$(date +%s)
            local cur_mem
            cur_mem=$(cat "$mem_path" 2>/dev/null || echo 0)
            mem_samples+=("${now},${cur_mem}")
        fi
    done

    # Wait for build to finish and capture exit code
    wait "$build_pid" 2>/dev/null || true
    local exit_code=$?

    local end_ts
    end_ts=$(date +%s)
    local build_time=$((end_ts - start_ts))

    # ---- Final CPU read ----
    local cpu_end_usec=$cpu_start_usec
    if [ -f "$cpu_path" ]; then
        cpu_end_usec=$(grep '^usage_usec ' "$cpu_path" 2>/dev/null | awk '{print $2}' || echo "$cpu_end_usec")
    fi
    local total_cpu_usec=$((cpu_end_usec - cpu_start_usec))

    # ---- Peak memory (read from file written by the build process) ----
    local peak_mem=0
    if [ -f "$peakfile" ]; then
        peak_mem=$(cat "$peakfile" 2>/dev/null || echo 0)
        rm -f "$peakfile"
    fi

    # ---- Average memory ----
    local avg_mem=0
    if [ ${#mem_samples[@]} -gt 0 ]; then
        local total_mem=0
        local count=0
        for sample in "${mem_samples[@]}"; do
            local val="${sample#*,}"
            total_mem=$((total_mem + val))
            count=$((count + 1))
        done
        if [ "$count" -gt 0 ]; then
            avg_mem=$((total_mem / count))
        fi
    fi

    # ---- rustc_driver.so size (original and stripped) ----
    local final_size=0
    local stripped_size=0
    local so
    so=$(find_so "$build_dir")
    if [ -n "$so" ] && [ -f "$so" ]; then
        final_size=$(stat -c%s "$so")
        stripped_size=$(measure_stripped_so "$build_dir")
    fi

    # ---- Determine status (addresses [5]) ----
    local status="OK"
    if [ "$exit_code" -ne 0 ]; then
        status="FAIL"
        echo "  ERROR: build exited with code $exit_code (see $logfile)" >&2
        tail -10 "$logfile" | sed 's/^/    /'
    fi

    # [7] CPU core computations
    local avg_cores_str
    local peak_cores_str
    if [ "$build_time" -gt 0 ] && [ "$total_cpu_usec" -gt 0 ]; then
        avg_cores_str=$(awk "BEGIN {printf \"%.2f\", ${total_cpu_usec} / ${build_time} / 1000000}" 2>/dev/null || echo "0")
    else
        avg_cores_str="0"
    fi
    peak_cores_str=$(awk "BEGIN {printf \"%.2f\", ${max_delta} / 1000000}" 2>/dev/null || echo "0")

    local mb=$((final_size / 1048576))
    local smb=$((stripped_size / 1048576))
    local pmb=$((peak_mem / 1048576))
    local amb=$((avg_mem / 1048576))
    echo "  Status: ${status}  Time: ${build_time}s  Driver: ${mb} MB  Stripped: ${smb} MB  Peak mem: ${pmb} MB  Avg mem: ${amb} MB"
    echo "  CPU: total=${total_cpu_usec}us  avg=${avg_cores_str} cores  peak=${peak_cores_str} cores"

    # Append to CSV (columns: step,label,status,unix_ts_start,unix_ts_end,wall_time_s,
    #                     rustc_driver_size_bytes,stripped_size_bytes,
    #                     peak_mem_bytes,avg_mem_bytes,
    #                     total_cpu_usec,max_cpu_usec_per_sec,avg_cpu_cores,peak_cpu_cores)
    echo "${step},${label},${status},${start_ts},${end_ts},${build_time}," \
         "${final_size},${stripped_size},${peak_mem},${avg_mem}," \
         "${total_cpu_usec},${max_delta},${avg_cores_str},${peak_cores_str}" \
         >> "$RESULTS_LOG"

    echo "  Logged to $RESULTS_LOG"
}

# ======================================================================
#  MAIN
# ======================================================================

# CSV header (columns: step,label,status,unix_ts_start,unix_ts_end,wall_time_s,
#                     rustc_driver_size_bytes,stripped_size_bytes,
#                     peak_mem_bytes,avg_mem_bytes,
#                     total_cpu_usec,max_cpu_usec_per_sec,avg_cpu_cores,peak_cpu_cores)
if [ ! -f "$RESULTS_LOG" ]; then
    echo "step,label,status,unix_ts_start,unix_ts_end,wall_time_s," \
         "rustc_driver_size_bytes,stripped_size_bytes,peak_mem_bytes,avg_mem_bytes," \
         "total_cpu_usec,max_cpu_usec_per_sec,avg_cpu_cores,peak_cpu_cores" \
         > "$RESULTS_LOG"
fi

# ---- Step 0: Stage1 sanity check ([6]) ----
check_stage1

# ---- Step 1: Default (stock Cargo, no size opts) ----
# Disable .cargo/config.toml so we get pure stock defaults (no LTO, cgu=16)
save_cargo_config

build_and_measure \
    1 "Default (stock, no size opts)" \
    "$ROOT/build-stage2-sizewalk-1" \
    "" \
    ""

# ---- Step 2: Standard size options (lto=FAT, cgu=1) ----
# Restore config.toml so lto=fat + cgu=1 are active.
#
# [2] Addressing "other size options we use/should use":
#   Current config.toml: lto="fat", codegen-units=1, profiler=true,
#                        download-ci-llvm=true.
#   Other candidates:
#     - lto = "thin"        — smaller binaries, weaker inlining than fat
#     - -Z hot-cold-split   — split hot/cold code paths
#     - -C panic=abort      — removes unwind tables (~5-10% smaller)
#     - -C embed-bitcode=no — smaller rlibs
#   These could be added as optional flags in a future iteration.
restore_cargo_config

build_and_measure \
    2 "Standard size opts (lto=fat cgu=1)" \
    "$ROOT/build-stage2-sizewalk-2" \
    "$ROOT/build-stage2-sizewalk-1" \
    ""

# ---- Step 2.5: Stripped standard size opts ----
# Takes the binary from step 2 and strips debug symbols to show the
# isolated effect of stripping (no other optimisation changes).
# Hard-links from step 2 so we don't copy the full tree.
strip_step() {
    local step="$1"
    local label="$2"
    local build_dir="$3"
    local base_dir="$4"

    local unit="sizewalk-${step}"

    echo ""
    echo "========================================================================"
    echo "  Step ${step}: ${label}"
    echo "  Build dir: ${build_dir}"
    echo "  Unit:      ${unit}.scope"
    echo "========================================================================"

    rm -rf "$build_dir"
    if [ -n "$base_dir" ] && [ -d "$base_dir" ]; then
        echo "  Hard-linking from ${base_dir} ..."
        cp -alT "$base_dir" "$build_dir"
        echo "  Done."
    fi

    local start_ts
    start_ts=$(date +%s)

    # Find the SO in the linked build dir
    local so
    so=$(find_so "$build_dir")
    if [ -z "$so" ] || [ ! -f "$so" ]; then
        echo "  ERROR: no librustc_driver.so found in $build_dir" >&2
        local end_ts; end_ts=$(date +%s)
        local build_time=$((end_ts - start_ts))
        echo "2.5,${label},FAIL,${start_ts},${end_ts},${build_time},0,0,0,0,0,0,0,0" >> "$RESULTS_LOG"
        return
    fi

    local original_size
    original_size=$(stat -c%s "$so")
    echo "  Original size: $((original_size / 1048576)) MB"

    # Strip a copy
    local stripped="${so}.stripped"
    cp "$so" "$stripped"
    strip --strip-debug "$stripped" 2>/dev/null || true
    local stripped_size
    stripped_size=$(stat -c%s "$stripped" 2>/dev/null || echo 0)

    local end_ts
    end_ts=$(date +%s)
    local build_time=$((end_ts - start_ts))

    local saved=$((original_size - stripped_size))
    echo "  Stripped size:  $((stripped_size / 1048576)) MB (saved $((saved / 1048576)) MB, $(awk "BEGIN {printf \"%.1f\", ${saved} / ${original_size} * 100}" 2>/dev/null || echo "?")%)"

    # Log to CSV (most metrics are 0/N/A for a strip-only step)
    echo "2.5,${label},OK,${start_ts},${end_ts},${build_time}," \
         "${original_size},${stripped_size},0,0," \
         "0,0,0,0" \
         >> "$RESULTS_LOG"
    echo "  Logged to $RESULTS_LOG"
}

strip_step \
    "2.5" "Standard size opts, striped" \
    "$ROOT/build-stage2-sizewalk-2.5" \
    "$ROOT/build-stage2-sizewalk-2"

# ---- Step 3: CGU-PGSO (per-CGU opt levels only) ----
if [ -f "$CGU_FILE_1X" ]; then
    build_and_measure \
        3 "CGU-PGSO (per-CGU opt levels)" \
        "$ROOT/build-stage2-sizewalk-3" \
        "$ROOT/build-stage2-sizewalk-2" \
        "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=${CGU_FILE_1X}"
else
    echo ""
    echo "  WARNING: $CGU_FILE_1X not found — skipping step 3"
fi

# ---- Step 4: CGU + fn PGSO ----
if [ -f "$CGU_FILE_1X" ] && [ -f "$FN_FILE_1X" ]; then
    build_and_measure \
        4 "CGU + fn PGSO" \
        "$ROOT/build-stage2-sizewalk-4" \
        "$ROOT/build-stage2-sizewalk-3" \
        "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=${CGU_FILE_1X} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $CGU_FILE_1X or $FN_FILE_1X not found — skipping step 4"
fi

# ---- Step 5: Brute-opt-quick refined ----
if [ -f "$CGU_BRUTE_QUICK" ] && [ -f "$FN_FILE_1X" ]; then
    build_and_measure \
        5 "Brute-opt-quick refined" \
        "$ROOT/build-stage2-sizewalk-5" \
        "$ROOT/build-stage2-sizewalk-4" \
        "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=${CGU_BRUTE_QUICK} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $CGU_BRUTE_QUICK or $FN_FILE_1X not found — skipping step 5"
fi

# ---- Step 6: Function-level PGSO only (no CGU overrides) ----
# Tests the impact of per-function opt levels in isolation, without any
# per-CGU overrides.  Hard-links from step 2 (standard size opts) so the
# baseline is the same as step 3 (CGU-only), enabling a clean A/B
# comparison between CGU-level and function-level optimisation.
if [ -f "$FN_FILE_1X" ]; then
    build_and_measure \
        6 "Fn-only PGSO (no CGU)" \
        "$ROOT/build-stage2-sizewalk-6" \
        "$ROOT/build-stage2-sizewalk-2" \
        "-Z human-readable-cgu-names -Z hot-cold-split -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $FN_FILE_1X not found — skipping step 6"
fi

# ======================================================================
#  Extreme size optimisation steps (7+)
# ======================================================================
# These steps push beyond the "safe" configurations above. Some may
# produce a compiler that crashes on certain inputs (e.g. panic=abort
# breaks catch_unwind, strip breaks backtraces). They are included to
# measure the absolute minimum binary size achievable.
#
# Each step hard-links from step 5 (the best "safe" configuration) to
# avoid rebuilding shared artifacts.
# ======================================================================

# ---- Step 7: panic=abort ----
# Removes all unwind landing pads from the standard library and compiler.
# This eliminates the `.eh_frame` section overhead and all catch_unwind
# cleanup code.  The resulting compiler will abort (not catch) panics,
# which means it may crash on malformed input that previously recovered.
#
# Size impact estimate: -5-10% from removed landing pads and unwind tables.
echo ""
echo "========================================================================="
echo "  Step 7: panic=abort (extreme — breaks catch_unwind)"
echo "========================================================================="
build_and_measure \
    7 "panic=abort (extreme)" \
    "$ROOT/build-stage2-sizewalk-7" \
    "$ROOT/build-stage2-sizewalk-5" \
    "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=${CGU_BRUTE_QUICK} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz" \
    --set rust.panic-abort=true

# ---- Step 8: panic=abort + strip=symbols ----
# Adds -Cstrip=symbols to remove all symbol names from the binary.
# This eliminates the .symtab and .strtab sections.  The compiler still
# works but backtraces become unreadable (just addresses).
#
# Size impact estimate: -10-15% from stripped symbols (depends on how
# many symbols LLVM retains after LTO).
echo ""
echo "========================================================================="
echo "  Step 8: panic=abort + strip=symbols (extreme)"
echo "========================================================================="
build_and_measure \
    8 "panic=abort+strip" \
    "$ROOT/build-stage2-sizewalk-8" \
    "$ROOT/build-stage2-sizewalk-7" \
    "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=${CGU_BRUTE_QUICK} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz" \
    --set rust.panic-abort=true --set rust.strip=symbols

# ---- Step 9: No-vectorize (PGSO + disable loop/SLP vectorization) ----
# Loop and SLP vectorization create versioned loops (scalar + vector +
# remainder) which bloat code.  Disabling them saves size at the cost
# of runtime on vectorizable workloads.  Keeps the brute-quick PGSO
# per-crate and per-function levels so this measures the isolated
# impact of vectorisation.
#
# Size impact estimate: -0.5-2% over step 5 (rustc has few hot loops).
echo ""
echo "========================================================================="
echo "  Step 9: No-vectorize (PGSO + no loop/SLP vec)"
echo "========================================================================="
build_and_measure \
    9 "No-vectorize" \
    "$ROOT/build-stage2-sizewalk-9" \
    "$ROOT/build-stage2-sizewalk-5" \
    "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=${CGU_BRUTE_QUICK} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz -C llvm-args=-vectorize-loops=false -C llvm-args=-slp-vectorize=false"

# ---- Step 10: Maximum extreme (panic=abort + strip + no-vec + no-merge) ----
# Combines ALL extreme options on top of PGSO:
#   - panic=abort: remove unwind tables
#   - strip=symbols: remove symbol names
#   - no-vectorize: disable loop/SLP vectorization
#   - no-merge-functions: disable MergeFunctions (saves link time)
# This is the absolute minimum size achievable without modifying rustc.
# The compiler WILL be unreliable (panic=abort breaks catch_unwind).
echo ""
echo "========================================================================="
echo "  Step 10: Maximum extreme (panic+strip+no-vec+PGSO)"
echo "========================================================================="
build_and_measure \
    10 "MAX extreme" \
    "$ROOT/build-stage2-sizewalk-10" \
    "$ROOT/build-stage2-sizewalk-8" \
    "-Z human-readable-cgu-names -Z hot-cold-split -Z cgu-opt-levels=${CGU_BRUTE_QUICK} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz -C llvm-args=-vectorize-loops=false -C llvm-args=-slp-vectorize=false" \
    --set rust.panic-abort=true --set rust.strip=symbols

# ======================================================================
#  Summary table
# ======================================================================
echo ""
echo "========================================================================="
echo "  Sizewalk Summary"
echo "========================================================================="
echo ""
printf "%-6s %-28s %-5s %-5s %-8s %-8s %-6s %-6s %-6s %-6s\n" \
    "Step" "Label" "Time" "Status" "Driver" "Stripp" "Peak" "Avg" "Avg" "Peak"
printf "%-6s %-28s %-5s %-5s %-8s %-8s %-6s %-6s %-6s %-6s\n" \
    "" "" "(s)" "" "(MB)" "(MB)" "Mem" "Mem" "CPU" "CPU"
printf "%s\n" "--------------------------------------------------------------------------"

while IFS=, read -r step label status ts_start ts_end wall_size \
    so_size stripped_size peak_mem avg_mem _total_cpu _max_cpu avg_cpu peak_cpu; do

    [ "$step" = "step" ] && continue

    # Strip quotes
    step="${step//\"/}";   label="${label//\"/}"
    status="${status//\"/}";  wall_size="${wall_size//\"/}"
    so_size="${so_size//\"/}";  stripped_size="${stripped_size//\"/}"
    peak_mem="${peak_mem//\"/}";  avg_mem="${avg_mem//\"/}"
    avg_cpu="${avg_cpu//\"/}";  peak_cpu="${peak_cpu//\"/}"

    : "${wall_size:=0}" "${so_size:=0}" "${stripped_size:=0}" "${peak_mem:=0}"
    : "${avg_mem:=0}"   "${avg_cpu:=0}"  "${peak_cpu:=0}"

    if [ ${#label} -gt 27 ]; then
        label="${label:0:24}..."
    fi

    printf "%-6s %-28s %-5s %-5s %-8s %-8s %-6s %-6s %-6s %-6s\n" \
        "$step" \
        "$label" \
        "${wall_size}s" \
        "$status" \
        "$((so_size / 1048576))" \
        "$((stripped_size / 1048576))" \
        "$((peak_mem / 1048576))" \
        "$((avg_mem / 1048576))" \
        "${avg_cpu}c" \
        "${peak_cpu}c"
done < "$RESULTS_LOG"

echo ""
echo "========================================================================="
echo "  Results saved to: $RESULTS_LOG"
echo "  Build logs in:    $BUILD_LOG_DIR"
echo "  Build dirs:"
for d in "$ROOT"/build-stage2-sizewalk-*; do
    [ -d "$d" ] && echo "    $d"
done
echo "========================================================================="

# ======================================================================
#  Appendix: Configuration reference
# ======================================================================
echo ""
echo "========================================================================="
echo "  Appendix — Configuration reference"
echo "========================================================================="
echo ""
echo "Step  Config"
echo "----  --------------------------------------------------------------"
echo "  0   Sanity check stage1 compiler"
echo "      - Builds stage1 (stage2 bootstrap) if missing"
echo "      - Runs 'rustc --version' smoke test"
echo ""
echo "  1   Default (stock Cargo)"
echo "      - .cargo/config.toml disabled"
echo "      - No LTO, codegen-units=16 (Cargo default)"
echo "      - Command: python3 x.py build --stage 2 compiler/rustc library/std"
echo ""
echo "  2   Standard size options"
echo "      - .cargo/config.toml active: lto=fat, codegen-units=1"
echo "      - RUSTFLAGS_NOT_BOOTSTRAP='' (no extra flags)"
echo ""
echo "  2.5 Stripped standard size opts"
echo "      - Copies step 2's build tree via hard links"
echo "      - Runs 'strip --strip-debug' on librustc_driver.so"
echo "      - Reports both original size (from step 2) and stripped size"
echo "      - All other metrics are 0/N/A (no build performed)"
echo ""
echo "  3   CGU-PGSO (per-CGU opt levels only)"
echo "      - Builds on step 2"
echo "      - RUSTFLAGS_NOT_BOOTSTRAP includes:"
echo "          -Z cgu-opt-levels=<cgu_opt_levels_1x.txt>"
echo "      - File:  build/pgo_data/cgu_opt_levels_1x.txt"
echo "      - Note: no -Z fn-opt-levels flag"
echo ""
echo "  4   CGU + fn PGSO (both per-CGU and per-function)"
echo "      - Builds on step 3"
echo "      - RUSTFLAGS_NOT_BOOTSTRAP includes:"
echo "          -Z cgu-opt-levels=<cgu_opt_levels_1x.txt>"
echo "          -Z fn-opt-levels=<fn_opt_levels_1x.txt>"
echo "          -Z fn-opt-level-default=Oz"
echo "      - Files: build/pgo_data/cgu_opt_levels_1x.txt"
echo "              build/pgo_data/fn_opt_levels_1x.txt"
echo ""
echo "  5   Brute-opt-quick refined"
echo "      - Builds on step 4"
echo "      - RUSTFLAGS_NOT_BOOTSTRAP includes:"
echo "          -Z cgu-opt-levels=<cgu_opt_levels_brute_quick.txt>"
echo "          -Z fn-opt-levels=<fn_opt_levels_1x.txt>"
echo "          -Z fn-opt-level-default=Oz"
echo "      - Files: build/pgo_data/cgu_opt_levels_brute_quick.txt"
echo "              build/pgo_data/fn_opt_levels_1x.txt"
echo ""
echo "  6   Function-level PGSO only (no CGU overrides)"
echo "      - Builds on step 2 (same baseline as step 3)"
echo "      - RUSTFLAGS_NOT_BOOTSTRAP includes:"
echo "          -Z fn-opt-levels=<fn_opt_levels_1x.txt>"
echo "          -Z fn-opt-level-default=Oz"
echo "      - File: build/pgo_data/fn_opt_levels_1x.txt"
echo "      - Note: no -Z cgu-opt-levels flag"
echo ""
echo "---"
echo ""
echo "Common flags in all PGSO steps (3-6):"
echo "  -Z human-readable-cgu-names     — readable CGU names for debugging"
echo "  -Z hot-cold-split               — split hot/cold code paths"
echo ""
echo "Common base for all steps:"
echo "  --build-dir <dir>  -j \$JOBS"
echo "  python3 x.py build --stage 2 compiler/rustc library/std"
echo ""
echo "---"
echo ""
echo "Metric sources:"
echo "  rustc_driver.so size   find .../stage2-rustc/*/release/librustc_driver.so"
echo "  Stripped size          strip --strip-debug copy, stat -c%s"
echo "  Wall clock             date +%s before/after"
echo "  Peak memory            memory.max_usage_in_bytes (cgroup v1)"
echo "  Average memory         memory.usage_in_bytes sampled every 1s"
echo "  Total CPU time         cpu.stat/usage_usec (cgroup v1, microseconds)"
echo "  Peak CPU (1s window)   max per-second delta of usage_usec"
echo "  Average CPU cores      total_cpu_usec / wall_time_s / 1e6"
echo "  Peak CPU cores         max_delta_usec / 1e6"
echo ""
echo "cgroup paths (under systemd scope):"
echo "  /sys/fs/cgroup/cpu/system.slice/sizewalk-<N>.scope/cpu.stat"
echo "  /sys/fs/cgroup/memory/system.slice/sizewalk-<N>.scope/memory.*"
echo ""
echo ""
echo "  7   panic=abort (extreme)"
echo "      - Builds on step 5"
echo "      - x.py flag: --set rust.panic-abort=true"
echo "      - Removes all unwind landing pads (.eh_frame)"
echo "      - CAUTION: compiler will abort on panics (catch_unwind broken)"
echo ""
echo "  8   panic=abort + strip=symbols (extreme)"
echo "      - Builds on step 7"
echo "      - x.py flag: --set rust.strip=symbols"
echo "      - Removes all symbol names (.symtab, .strtab)"
echo "      - CAUTION: backtraces become unreadable"
echo ""
echo "  9   All-Oz + no-vectorize (extreme)"
echo "      - Builds on step 5"
echo "      - Forces all crates to Oz (max per-function size opt)"
echo "      - Adds -C llvm-args=-vectorize-loops=false"
echo "      - Adds -C llvm-args=-slp-vectorize=false"
echo ""
echo "  10  Maximum extreme (panic=abort + strip + All-Oz + no-vec)"
echo "      - Builds on step 8"
echo "      - Combines all extreme options above"
echo "      - Absolute minimum size (potentially unreliable compiler)"
echo ""
echo "---"
echo ""
echo "Common flags in extreme steps (7-10):"
echo "  -Z human-readable-cgu-names     — readable CGU names"
echo "  -Z hot-cold-split               — split hot/cold code paths"
echo "  -Z cgu-opt-levels=<...>         — per-CGU opt levels"
echo "  -Z fn-opt-levels=<...>          — per-function opt levels"
echo ""
echo "Extreme options used in steps 7-10:"
echo "  --set rust.panic-abort=true     — removes unwind tables (~5-10% smaller)"
echo "  --set rust.strip=symbols        — removes all symbols (~10-15% smaller)"
echo "  -C llvm-args=-vectorize-loops=false  — no loop vectorization"
echo "  -Z cgu-opt-levels=<CGU_BRUTE_QUICK>       — brute-quick PGSO per-crate levels"
echo "  -Z cgu-opt-levels=*_Oz.txt           — all crates at Oz"
echo ""
echo "Other size options considered (not in this walk):"
echo "  - lto = 'thin'              — smaller than FAT, weaker inlining"
echo "  - -C embed-bitcode=no       — smaller rlibs (no bitcode in archives)"
echo "  - -Z merge-functions=...    — merge identical functions (LLVM)"
echo "  - -Z tls-model=...          — TLS model selection"
echo "  These can be added as optional flags in future iterations."
echo ""
echo "========================================================================="
