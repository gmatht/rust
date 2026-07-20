#!/usr/bin/env bash
# sizewalk-upstream-first.sh — Upstream-first variant of sizewalk.sh
#
# Step 2 bundles ALL upstream size optimisations (standard + extreme)
# before any PGSO is introduced.  Subsequent steps layer PGSO (per-CGU
# and per-function opt levels) on top of that fully-optimised base.
#
# Steps (all use x.py build --stage 2 — the stage2 driver is what we measure):
#   1. Default (stock Cargo, no size opts)
#   2. All upstream size opts (lto=fat, cgu=1, panic=abort, strip=symbols,
#      human-readable-cgu-names)
#   3. Step 2 + Oz everywhere (uniform -C opt-level=Oz, no PGSO)  — baseline
#   4. Step 2 + hot-cold-split + CGU-PGSO (per-CGU opt levels)    — 1x file
#   5. Step 4 + fn PGSO (per-function opt levels)                  — 1x files
#   6. Step 5 + brute-opt-quick (normal opt-levels only)           — brute_quick
#   7. Step 6 + brute-opt-quick (incl. size-tweak opt-levels)      — with_tweaks
#   8. Step 2 + hot-cold-split + fn-only PGSO (no CGU overrides, for A/B)
#
# Each step measures:
#   - rustc_driver.so size (original and stripped)
#   - Wall clock build time
#   - Average and max CPU utilisation (cores)
#   - Peak and average memory usage
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${JOBS:-4}"
RESULTS_LOG="$ROOT/sizewalk-upstream-first-results.csv"
BUILD_LOG_DIR="/tmp/sizewalk-upstream-first-logs"
PGO_DATA="$ROOT/build/pgo_data"

CGU_FILE_1X="$PGO_DATA/cgu_opt_levels_1x.txt"
FN_FILE_1X="$PGO_DATA/fn_opt_levels_final.txt"
CGU_BRUTE_QUICK="$PGO_DATA/cgu_opt_levels_brute_quick.txt"
CGU_BRUTE_QUICK_TWEAKS="$PGO_DATA/cgu_opt_levels_brute_quick_with_tweaks.txt"

mkdir -p "$BUILD_LOG_DIR"

# Parse --skipto option to skip steps before the given number
SKIPTO=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skipto)
            SKIPTO="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

run_step() {
    local step_num="$1"
    if [ "$step_num" -lt "$SKIPTO" ] 2>/dev/null; then
        echo "  Skipping step $step_num (--skipto=$SKIPTO)"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# [6] Stage1 sanity helpers
# ---------------------------------------------------------------------------
STAGE1_RUSTC="$ROOT/build/x86_64-unknown-linux-gnu/stage1/bin/rustc"
STAGE1_CARGO="$(which cargo)"

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
    # We build --stage 2, so the driver lives under stage2-rustc.
    # Exclude stale subdirectories from previous experiment runs that
    # were carried over via hard-link from the template.
    local so
    so=$(find "$build_dir" -name 'librustc_driver.so' \
        -path '*/stage2-rustc/*/release/*' \
        ! -path '*/upstream-pgso-test/*' \
        ! -path '*/unified-opt/*' \
        2>/dev/null | head -1)
    echo "$so"
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
# Parse build log for CGU and fn override match counts.
# Prints summary to stdout.
# Returns 2 if 0 CGU matches when overrides were expected (has_cgu=yes).
# Returns 3 if 0 fn matches when overrides were expected (has_fn=yes).
# ---------------------------------------------------------------------------
parse_override_matches() {
    local logfile="$1"
    local has_cgu="$2"   # "yes" if CGU overrides were passed in rustflags
    local has_fn="$3"    # "yes" if fn overrides were passed

    local cgu_matched=0 cgu_total=0 cgu_unmatched=0
    local fn_matched=0 fn_total=0 fn_unmatched=0

    while IFS= read -r line; do
        if [[ "$line" =~ cgu_opt_levels:\ ([0-9]+)\ entries\ unmatched,\ ([0-9]+)/([0-9]+)\ CGUs\ defaulting ]]; then
            local u="${BASH_REMATCH[1]}"
            local d="${BASH_REMATCH[2]}"
            local t="${BASH_REMATCH[3]}"
            cgu_unmatched=$((cgu_unmatched + u))
            cgu_matched=$((cgu_matched + t - d))
            cgu_total=$((cgu_total + t))
        fi
        if [[ "$line" =~ fn_opt_levels:\ ([0-9]+)\ entries\ unmatched,\ ([0-9]+)/([0-9]+)\ functions\ defaulting ]]; then
            local u="${BASH_REMATCH[1]}"
            local d="${BASH_REMATCH[2]}"
            local t="${BASH_REMATCH[3]}"
            fn_unmatched=$((fn_unmatched + u))
            fn_matched=$((fn_matched + t - d))
            fn_total=$((fn_total + t))
        fi
    done < <(grep -E 'warning: (cgu|fn)_opt_levels:' "$logfile" 2>/dev/null || true)

    echo "  CGU overrides: $cgu_matched/$cgu_total CGUs matched ($cgu_unmatched file entries unmatched)"
    echo "  Fn overrides:  $fn_matched/$fn_total functions matched ($fn_unmatched file entries unmatched)"

    # Abort if 0 matches when overrides were expected
    if [ "$has_cgu" = "yes" ] && [ "$cgu_total" -gt 0 ] && [ "$cgu_matched" -eq 0 ]; then
        echo "  ERROR: 0 CGU overrides matched — aborting!" >&2
        return 2
    fi
    if [ "$has_fn" = "yes" ] && [ "$fn_total" -gt 0 ] && [ "$fn_matched" -eq 0 ]; then
        echo "  ERROR: 0 function overrides matched — aborting!" >&2
        return 3
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Extract crate compilation events (timestamps) from a timestamped build log.
# Prints lines for "Compiling", "Finished", and "Building" events.
# ---------------------------------------------------------------------------
extract_compile_events() {
    local logfile="$1"
    echo "  Compilation events (crate starts and cargo invocations):"
    grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] (   Compiling |    Finished |Building )' "$logfile" 2>/dev/null | \
        sed 's/^\[\([^]]*\)\] \(.*\)/    [\1] \2/' || echo "    (none found in log)"
}

# ---------------------------------------------------------------------------
# Core: build under systemd-run, poll cgroups, log results.
#
# Usage:  build_and_measure <step> <label> <build-dir> <base-dir> \
#                            "<rustflags>" [<extra-xpy-args>...]
#
#   <step>     – integer step number (1-8)
#   <label>    – human-readable label
#   <build-dir> – where to build (will be rm -rf'd first)
#   <base-dir>  – existing tree to hard-link from, or "" for fresh
#   <rustflags> – value for RUSTFLAGS_NOT_BOOTSTRAP (empty string ok)
#   <extra-xpy-args> – any additional flags passed to x.py (optional)
#
# Build dir reuse: Each step gets a fresh rm -rf'd directory.
# Hard linking: cp -alT from <base-dir> preserves unchanged artifacts.
# Job count: $JOBS env var (default 4).
# Dependency download: only step 1 downloads LLVM; steps 2+ reuse.
# Error handling: on failure, status=FAIL is logged and script continues.
# CPU core calculation: avg = total_cpu_usec / (wall_s * 1e6),
#                       peak = max_delta_usec / 1e6.
#
# Note: We build --stage 1 throughout (stage0->stage1).  All desired
# RUSTFLAGS are passed via RUSTFLAGS_NOT_BOOTSTRAP, which applies to
# the stage1 artifacts.  There is no stage2 — the stage1 driver is
# what we measure.  This avoids the profile mismatch and redundant
# rebuilds that happen with --stage 2.
# ---------------------------------------------------------------------------
build_and_measure() {
    local step="$1"
    local label="$2"
    local build_dir="$3"
    local base_dir="$4"
    local rustflags="$5"
    shift 5
    local extra_args=("$@")

    local unit="sizewalk-up-${step}"
    local logfile="$BUILD_LOG_DIR/build-${step}.log"
    local peakfile="/tmp/sizewalk-up-peak-${step}.txt"

    echo ""
    echo "========================================================================"
    echo "  Step ${step}: ${label}"
    echo "  Build dir: ${build_dir}"
    echo "  Unit:      ${unit}.scope"
    echo "========================================================================"

    # Fresh build dir
    rm -rf "$build_dir"

    # Hard-link from base if available (preserves LLVM, libstd, etc.)
    if [ -n "$base_dir" ] && [ -d "$base_dir" ]; then
        echo "  Hard-linking from ${base_dir} ..."
        cp -alT "$base_dir" "$build_dir"
        echo "  Done."
    fi

    # All flags go into RUSTFLAGS_NOT_BOOTSTRAP instead of
    # RUSTFLAGS_BOOTSTRAP so they don't reach the stage0 probe.
    # RUSTFLAGS_NOT_BOOTSTRAP only applies to stage 1+ builds;
    # the stage0 bootstrap uses RUSTFLAGS_BOOTSTRAP (empty here).    # ----------------------------------------------------------------
    # CRITICAL: Delete ALL stale rlibs/rmeta files from the hard-linked
    # build directory.  If we don't do this, cargo's fingerprinting sees
    # that the rlibs are up-to-date (same mtime, same content hash) and
    # SKIPS recompilation even when RUSTFLAGS have changed.  The result
    # is that every step produces the same binary — the flags are ignored.
    #
    # By deleting all rlibs, we force cargo to rebuild every crate from
    # source with the new flags.  The hard links still save time on
    # non-rlib artifacts (LLVM objects, source trees, download cache).
    #
    # We clean both stage1-rustc and stage1/lib/rustlib paths to cover
    # compiler crates and library crates respectively.
    # ----------------------------------------------------------------
    local cleaned=0
    # Nuke ALL cargo target directories so cargo sees a completely empty
    # target and MUST rebuild everything from scratch with the new RUSTFLAGS.
    # The hard-link from the base dir still saves time on non-rustc artifacts
    # (LLVM objects, download cache, source trees, stage0/stage1 toolchains).
    # Clean stage2-rustc so stage2 compiler is rebuilt with new flags.
    # Keep stage1-rustc/stage1-std (they're the bootstrap compiler, not our target).
    for cargo_target in \
        "$build_dir"/x86_64-unknown-linux-gnu/stage2-rustc; do
        if [ -d "$cargo_target" ]; then
            local rlib_count
            rlib_count=$(find "$cargo_target" -name '*.rlib' 2>/dev/null | wc -l)
            cleaned=$((cleaned + rlib_count))
            rm -rf "$cargo_target" 2>/dev/null || true
        fi
    done
    [ "$cleaned" -gt 0 ] && echo "  Cleaned $cleaned stale rlib(s)/rmeta to force rebuild with new flags"

    local start_ts
    start_ts=$(date +%s)

    # Each log line is prefixed with a wall-clock timestamp via awk.
    local ts_awk_prog='{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush() }'

    # Construct the build command for systemd-run.
    # We use /usr/bin/time to capture total user+sys CPU time, because
    # cpu.stat on this kernel lacks usage_usec (only nr_periods/throttled).
    local timefile="/tmp/sizewalk-up-time-${step}.txt"
    rm -f "$timefile"
    local build_cmd
    printf -v build_cmd 'cd %q && RUSTC_BOOTSTRAP=1 RUSTFLAGS_NOT_BOOTSTRAP=%q \
        /usr/bin/time --quiet -o %q -f "CPU_REAL:%%e CPU_USER:%%U CPU_SYS:%%S CPU_PERC:%%P" \
        python3 x.py build --stage 2 compiler/rustc library/std --build-dir %q -j %d --set rust.deny-warnings=false %s 2>&1 \
        | awk '\''%s'\'' >%q; rc=${PIPESTATUS[0]}; \
        echo -n $(cat /sys/fs/cgroup/memory/system.slice/%s.scope/memory.max_usage_in_bytes 2>/dev/null || echo 0) >%q; \
        exit $rc' \
        "$ROOT" \
        "$rustflags" \
        "$timefile" \
        "$build_dir" \
        "$JOBS" \
        "${extra_args[*]}" \
        "$ts_awk_prog" \
        "$logfile" \
        "$unit" \
        "$peakfile"

    systemd-run --scope --unit="$unit" bash -c "$build_cmd" &
    local build_pid=$!

    # cgroup paths (memory only — cpu.stat doesn't have usage_usec on this kernel)
    local mem_path="/sys/fs/cgroup/memory/system.slice/${unit}.scope/memory.usage_in_bytes"
    local mem_samples=()

    # Wait for memory cgroup to appear (up to 5 s)
    local i=0
    while [ ! -f "$mem_path" ] && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    # Poll memory every second while the build is alive
    while kill -0 "$build_pid" 2>/dev/null; do
        sleep 1
        if [ -f "$mem_path" ]; then
            local now
            now=$(date +%s)
            local cur_mem
            cur_mem=$(cat "$mem_path" 2>/dev/null || echo 0)
            mem_samples+=("${now},${cur_mem}")
        fi
    done

    # Wait for build to finish and capture exit code
    # (use || exit_code=$? so set -e doesn't kill us on build failure)
    local exit_code=0
    wait "$build_pid" 2>/dev/null || exit_code=$?

    local end_ts
    end_ts=$(date +%s)
    local build_time=$((end_ts - start_ts))

    # ---- Total CPU time from /usr/bin/time output ----
    local total_cpu_usec=0
    local max_delta=0
    if [ -f "$timefile" ]; then
        local cpu_real cpu_user cpu_sys
        cpu_user=$(grep -oP 'CPU_USER:\K[0-9.]+' "$timefile" 2>/dev/null || echo 0)
        cpu_sys=$(grep -oP 'CPU_SYS:\K[0-9.]+' "$timefile" 2>/dev/null || echo 0)
        # time reports in seconds with fractions; convert to microseconds
        total_cpu_usec=$(awk "BEGIN {printf \"%d\", ($cpu_user + $cpu_sys) * 1000000}" 2>/dev/null || echo 0)
        rm -f "$timefile"
    fi

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

    # ---- Determine status ----
    local status="OK"
    if [ "$exit_code" -ne 0 ]; then
        status="FAIL"
        echo "  ERROR: build exited with code $exit_code (see $logfile)" >&2
        tail -10 "$logfile" | sed 's/^/    /'
    fi

    # CPU core computations
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

    # Append to CSV
    echo "${step},${label},${status},${start_ts},${end_ts},${build_time}," \
         "${final_size},${stripped_size},${peak_mem},${avg_mem}," \
         "${total_cpu_usec},${max_delta},${avg_cores_str},${peak_cores_str}" \
         >> "$RESULTS_LOG"

    echo "  Logged to $RESULTS_LOG"

    # ---- Step summary with CGU/fn override stats and compile events ----
    echo ""
    echo "  ─── Step ${step} Summary ───"
    echo "  Build:     ${build_time}s  |  Driver: ${mb} MB  Stripped: ${smb} MB"
    echo "  Memory:    peak ${pmb} MB  avg ${amb} MB"
    echo "  CPU:       avg ${avg_cores_str}c  peak ${peak_cores_str}c"

    # Determine whether CGU/fn overrides were expected in rustflags
    local has_cgu="no"
    local has_fn="no"
    case "$rustflags" in
        *cgu-opt-levels=*) has_cgu="yes" ;;&
        *fn-opt-levels=*)  has_fn="yes" ;;&
    esac

    # Parse override match stats from the log
    if [ "$has_cgu" = "yes" ] || [ "$has_fn" = "yes" ]; then
        if ! parse_override_matches "$logfile" "$has_cgu" "$has_fn"; then
            local rc=$?
            echo "  ABORTING due to override match failure (code $rc)" >&2
            exit $rc
        fi
    else
        echo "  (no CGU/fn overrides in this step)"
    fi

    # Extract crate compilation events from the timestamped log
    extract_compile_events "$logfile"
    echo "  ────────────────────────────────"
    echo ""
}

# ======================================================================
#  MAIN
# ======================================================================

# Clear any stale systemd scopes from previous runs
for u in sizewalk-up-{1,2,3,4,5,6,7,8}.scope; do
    systemctl stop "$u" 2>/dev/null || true
done
systemctl reset-failed 2>/dev/null || true

# CSV header
if [ ! -f "$RESULTS_LOG" ]; then
    echo "step,label,status,unix_ts_start,unix_ts_end,wall_time_s," \
         "rustc_driver_size_bytes,stripped_size_bytes,peak_mem_bytes,avg_mem_bytes," \
         "total_cpu_usec,max_cpu_usec_per_sec,avg_cpu_cores,peak_cpu_cores" \
         > "$RESULTS_LOG"
fi

# Record overall start time
TOTAL_START_SECONDS=$(date +%s)

# ---- Step 0: Stage1 sanity check ----
check_stage1

# ---- Step 1: Default (stock Cargo, no size opts) ----
save_cargo_config

if run_step 1; then
build_and_measure \
    1 "Default (stock, no size opts)" \
    "$ROOT/build-stage2-up-first-1" \
    "$ROOT/build" \
    "" \
    --set rust.lto=thin-local --set rust.codegen-units=16
fi

# ---- Step 2: All upstream size optimisations ----
# Combines every size-saving upstream rustc option — standard AND extreme —
# so we get the full upstream baseline before layering PGSO.
#
# Options bundled:
#   - lto=fat, codegen-units=1          (from .cargo/config.toml)
#   - -Z human-readable-cgu-names        (readable CGU names)
#   - -C panic=abort                     (remove unwind tables, -5-10%)
#   - -C strip=symbols                   (remove symbol names, -10-15%)
#
# NOT included here (deferred to PGSO steps):
#   - -Z hot-cold-split                  — this is a PGSO-adjacent flag,
#                                          leave it for the PGSO layers
#   - -C llvm-args=-vectorize-loops=false — opt-level-like, skip
#   - -C llvm-args=-slp-vectorize=false   — opt-level-like, skip
#
# These are all upstream (available in nightly rustc without PGSO patches).
restore_cargo_config

# Build RUSTFLAGS from all upstream size options
UPSTREAM_OPT_FLAGS="-Z human-readable-cgu-names \
    -C strip=symbols"
# Note: -C panic=abort is intentionally omitted because it breaks
# proc-macro crates (proc_macro crate is unavailable under panic=abort).
# If you need panic=abort, apply it via target-specific rustflags.

if run_step 2; then
build_and_measure \
    2 "All upstream size opts" \
    "$ROOT/build-stage2-up-first-2" \
    "$ROOT/build-stage2-up-first-1" \
    "$UPSTREAM_OPT_FLAGS"
fi

# ---- Step 3: Oz everywhere (uniform, no PGSO) ----
if run_step 3; then
build_and_measure \
    3 "Upstream + Oz everywhere (no PGSO)" \
    "$ROOT/build-stage2-up-first-3" \
    "$ROOT/build-stage2-up-first-2" \
    "$UPSTREAM_OPT_FLAGS -C opt-level=z"
fi

# ---- Step 4: CGU-PGSO (per-CGU opt levels only) ----
if run_step 4 && [ -f "$CGU_FILE_1X" ]; then
    build_and_measure \
        4 "CGU-PGSO (per-CGU opt levels)" \
        "$ROOT/build-stage2-up-first-4" \
        "$ROOT/build-stage2-up-first-3" \
        "$UPSTREAM_OPT_FLAGS -Z hot-cold-split -Z cgu-opt-levels=${CGU_FILE_1X}"
else
    echo ""
    echo "  WARNING: $CGU_FILE_1X not found — skipping step 4"
fi

# ---- Step 5: CGU + fn PGSO ----
if run_step 5 && [ -f "$CGU_FILE_1X" ] && [ -f "$FN_FILE_1X" ]; then
    build_and_measure \
        5 "CGU + fn PGSO" \
        "$ROOT/build-stage2-up-first-5" \
        "$ROOT/build-stage2-up-first-4" \
        "$UPSTREAM_OPT_FLAGS -Z hot-cold-split -Z cgu-opt-levels=${CGU_FILE_1X} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $CGU_FILE_1X or $FN_FILE_1X not found — skipping step 5"
fi

# ---- Step 6: Brute-opt-quick (normal opt-levels only) ----
# Uses the brute-opt-quick per-CGU level assignments, which were derived
# by measuring each crate at every standard opt-level (Oz, Os, O1, O2, O3)
# and selecting the level that minimises .text size.  No size-tweak
# variants are considered here — only stock opt-levels.
if run_step 6 && [ -f "$CGU_BRUTE_QUICK" ] && [ -f "$FN_FILE_1X" ]; then
    build_and_measure \
        6 "Brute-opt-quick (normal opt-levels)" \
        "$ROOT/build-stage2-up-first-6" \
        "$ROOT/build-stage2-up-first-5" \
        "$UPSTREAM_OPT_FLAGS -Z hot-cold-split -Z cgu-opt-levels=${CGU_BRUTE_QUICK} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $CGU_BRUTE_QUICK or $FN_FILE_1X not found — skipping step 6"
fi

# ---- Step 7: Brute-opt-quick (incl. size-tweak opt-levels) ----
# Like step 6, but the brute-opt-quick measurement also considered
# "funky" size-tweak variants of O2 and O3 with LLVM codegen tunables
# that inhibit code-size-increasing transformations:
#   O2-no-unroll            O2 + -llvm-opt=unroll=false
#   O2-no-unroll-no-vec     O2 + unroll=false, slp=false, loop=false
#   O3-no-unroll            O3 + unroll=false
#   O3-no-unroll-no-vec     O3 + unroll=false, slp=false, loop=false
#
# The resulting CGU file may assign some crates to these tweak levels
# where they produce smaller code than any standard opt-level.
#
# Requires: scripts/brute-opt-quick.sh --size-tweaks
CGU_BRUTE_QUICK_TWEAKS_EXISTS=false
if [ -f "$CGU_BRUTE_QUICK_TWEAKS" ]; then
    CGU_BRUTE_QUICK_TWEAKS_EXISTS=true
fi

if false && [ "$CGU_BRUTE_QUICK_TWEAKS_EXISTS" = true ] && [ -f "$FN_FILE_1X" ]; then
    build_and_measure \
        7 "Brute-opt-quick (incl. size-tweaks)" \
        "$ROOT/build-stage2-up-first-7" \
        "$ROOT/build-stage2-up-first-6" \
        "$UPSTREAM_OPT_FLAGS -Z hot-cold-split -Z cgu-opt-levels=${CGU_BRUTE_QUICK_TWEAKS} -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $CGU_BRUTE_QUICK_TWEAKS not found — skipping step 7"
    echo "  Run 'brute-opt-quick.sh --size-tweaks' first to generate it."
fi

# ---- Step 8: Function-level PGSO only (no CGU overrides) ----
# Hard-links from step 2 (upstream base only, no PGSO) so the baseline
# matches step 4, giving a clean A/B comparison between CGU-level and
# function-level optimisation.
if run_step 8 && [ -f "$FN_FILE_1X" ]; then
    build_and_measure \
        8 "Fn-only PGSO (no CGU overrides)" \
        "$ROOT/build-stage2-up-first-8" \
        "$ROOT/build-stage2-up-first-2" \
        "$UPSTREAM_OPT_FLAGS -Z hot-cold-split -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $FN_FILE_1X not found — skipping step 8"
fi

# ---- Step 9: CGU-PGSO without hot-cold-split (isolates CGU opt effect) ----
if [ -f "$CGU_FILE_1X" ]; then
    build_and_measure \
        9 "CGU-PGSO (no hot-cold-split)" \
        "$ROOT/build-stage2-up-first-9" \
        "$ROOT/build-stage2-up-first-2" \
        "$UPSTREAM_OPT_FLAGS -Z cgu-opt-levels=${CGU_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $CGU_FILE_1X not found — skipping step 9"
fi

# ---- Step 10: Hot-cold-split with O3 hot / Oz cold CGUs (no fn-level) ----
# Each crate is split into hot/cold CGUs. Hot CGUs match .hot prefix and get O3,
# cold CGUs default to Oz. No per-function opt levels.
HOT_CGUS="$PGO_DATA/hot_cgus.txt"
if [ -f "$HOT_CGUS" ]; then
    build_and_measure \
        10 "Hot-cold O3 hot / Oz cold (CGU)" \
        "$ROOT/build-stage2-up-first-10" \
        "$ROOT/build-stage2-up-first-2" \
        "$UPSTREAM_OPT_FLAGS -Z hot-cold-split=yes -Z cgu-opt-levels=${HOT_CGUS} -Z cgu-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $HOT_CGUS not found — skipping step 10"
fi

# ---- Step 11: Hot-cold-split + per-function opt levels on top ----
# Same as step 10 but adds fn-opt-levels for per-function refinement.
if [ -f "$HOT_CGUS" ] && [ -f "$FN_FILE_1X" ]; then
    build_and_measure \
        11 "Hot-cold + fn PGSO" \
        "$ROOT/build-stage2-up-first-11" \
        "$ROOT/build-stage2-up-first-10" \
        "$UPSTREAM_OPT_FLAGS -Z hot-cold-split=yes -Z cgu-opt-levels=${HOT_CGUS} -Z cgu-opt-level-default=Oz -Z fn-opt-levels=${FN_FILE_1X} -Z fn-opt-level-default=Oz"
else
    echo ""
    echo "  WARNING: $HOT_CGUS or $FN_FILE_1X not found — skipping step 11"
fi

# ======================================================================
#  Summary table
# ======================================================================
echo ""
echo "========================================================================="
echo "  Sizewalk (Upstream-first) Summary"
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
for d in "$ROOT"/build-stage2-up-first-*; do
    [ -d "$d" ] && echo "    $d"
done
echo "========================================================================="

# ======================================================================
#  Appendix — Configuration reference
# ======================================================================
echo ""
echo "========================================================================="
echo "  Appendix — Configuration reference"
echo "========================================================================="
echo ""
echo "Step  Config"
echo "----  --------------------------------------------------------------"
echo "  0   Sanity check stage1 compiler"
echo "      - Builds stage1 (via --stage 1) if missing"
echo "      - Runs 'rustc --version' smoke test"
echo ""
echo "  1   Default (stock Cargo)"
echo "      - .cargo/config.toml disabled"
echo "      - x.py flags: --set rust.lto=thin-local --set rust.codegen-units=16"
echo "      - Overrides config.toml's lto=fat and codegen-units=1 to defaults"
echo ""
echo "  2   All upstream size optimisations"
echo "      - .cargo/config.toml active: lto=fat, codegen-units=1"
echo "      - x.py flags: (none — all via RUSTFLAGS)"
echo "      - RUSTFLAGS_NOT_BOOTSTRAP includes:"
echo "          -Z human-readable-cgu-names"
echo "          -C panic=abort"
echo "          -C strip=symbols"
echo "      - NOT included (deferred to PGSO steps):"
echo "          -Z hot-cold-split           — PGSO-adjacent, added with PGSO"
echo "          -C llvm-args=-no-vec...     — opt-level-like, skipped"
echo "      - Source: combines standard size opts (lto=fat, cgu=1)"
echo "        with panic=abort and strip=symbols."
echo ""
echo "  3   Upstream + Oz everywhere (uniform, no PGSO)"
echo "      - Builds on step 2"
echo "      - Adds -C opt-level=Oz (via RUSTFLAGS)"
echo "      - Builds --stage 1 (stage0->stage1), no stage2"
echo "      - No hot-cold-split, no PGSO"
echo "      - Purpose: baseline to compare PGSO against uniform Oz"
echo ""
echo "  4   CGU-PGSO (per-CGU opt levels only)"
echo "      - Builds on step 3"
echo "      - Adds -Z hot-cold-split"
echo "      - RUSTFLAGS adds: -Z cgu-opt-levels=<cgu_opt_levels_1x.txt>"
echo "      - File: build/pgo_data/cgu_opt_levels_1x.txt"
echo "      - Note: no -Z fn-opt-levels flag"
echo ""
echo "  5   CGU + fn PGSO (both per-CGU and per-function)"
echo "      - Builds on step 4"
echo "      - RUSTFLAGS adds:"
echo "          -Z fn-opt-levels=<fn_opt_levels_1x.txt>"
echo "          -Z fn-opt-level-default=Oz"
echo "      - Files: build/pgo_data/cgu_opt_levels_1x.txt"
echo "              build/pgo_data/fn_opt_levels_1x.txt"
echo ""
echo "  6   Brute-opt-quick (normal opt-levels only)"
echo "      - Builds on step 5"
echo "      - Uses per-CGU levels from brute-opt-quick, considering"
echo "        only standard opt-levels: Oz, Os, O1, O2, O3"
echo "      - RUSTFLAGS uses:"
echo "          -Z cgu-opt-levels=<cgu_opt_levels_brute_quick.txt>"
echo "          -Z fn-opt-levels=<fn_opt_levels_1x.txt>"
echo "      - Files: build/pgo_data/cgu_opt_levels_brute_quick.txt"
echo "              build/pgo_data/fn_opt_levels_1x.txt"
echo ""
echo "  7   Brute-opt-quick (incl. size-tweak opt-levels)"
echo "      - Builds on step 6"
echo "      - Like step 6, but brute-opt-quick additionally considered"
echo "        size-tweak variants of O2 and O3 (no-unroll, no-vec)."
echo "      - Some crates may be assigned tweak levels instead of stock."
echo "      - RUSTFLAGS uses:"
echo "          -Z cgu-opt-levels=<cgu_opt_levels_brute_quick_with_tweaks.txt>"
echo "          -Z fn-opt-levels=<fn_opt_levels_1x.txt>"
echo "      - Requires: scripts/brute-opt-quick.sh --size-tweaks"
echo ""
echo "  8   Function-level PGSO only (no CGU overrides)"
echo "      - Builds on step 2 (same baseline as step 4)"
echo "      - RUSTFLAGS adds:"
echo "          -Z fn-opt-levels=<fn_opt_levels_1x.txt>"
echo "          -Z fn-opt-level-default=Oz"
echo "      - File: build/pgo_data/fn_opt_levels_1x.txt"
echo "      - Note: no -Z cgu-opt-levels flag"
echo ""
echo "---"
echo ""
echo "Common flags in all PGSO steps (4-8):"
echo "  -Z hot-cold-split               — split hot/cold code paths (PGSO-adjacent)"
echo "  -Z human-readable-cgu-names     — readable CGU names"
echo ""
echo "Common upstream base (steps 2-8):"
echo "  lto=fat, codegen-units=1          (from config.toml)"
echo "  -C panic=abort                    (via RUSTFLAGS)"
echo "  -C strip=symbols                  (via RUSTFLAGS)"
echo ""
echo "Common base for all steps:"
echo "  --build-dir <dir>  -j \$JOBS"
echo "  python3 x.py build --stage 1 compiler/rustc library/std"
echo ""
echo "---"
echo ""
echo "Metric sources:"
echo "  rustc_driver.so size   find .../stage1-rustc/*/release/librustc_driver.so"
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
echo "  /sys/fs/cgroup/cpu/system.slice/sizewalk-up-<N>.scope/cpu.stat"
echo "  /sys/fs/cgroup/memory/system.slice/sizewalk-up-<N>.scope/memory.*"
echo ""
echo "---"
echo ""
echo "Why upstream-first?"
echo ""
echo "The original sizewalk.sh scatters non-PGSO size options across"
echo "steps 2 (standard), 7 (panic=abort), 8 (strip), and 9 (no-vec),"
echo "each building on different PGSO bases.  This makes it hard to"
echo "answer the question: 'How much does PGSO save beyond what we can"
echo "get from upstream flags alone?'"
echo ""
echo "By bundling ALL upstream size options into step 2, this variant"
echo "provides a single maximally-optimised non-PGSO baseline.  Step 3"
echo "adds uniform Oz (no PGSO) to show the effect of a simple size-focus"
echo "flag.  Steps 4-8 then layer PGSO on top, so each increment shows"
echo "ONLY the marginal benefit of PGSO over a fully-optimised upstream"
echo "compiler."
echo ""
echo "Comparison with original sizewalk.sh:"
echo ""
echo "  Original sizewalk           Upstream-first variant"
echo "  -------------------------   -----------------------------------"
echo "  Step 2: lto=fat, cgu=1      Step 2: lto=fat, cgu=1"
echo "                                  + panic=abort"
echo "                                  + strip=symbols"
echo ""
echo "  (no equiv)                  Step 3: All upstream + Oz everywhere"
echo "                                  (uniform -C opt-level=Oz, no PGSO)"
echo ""
echo "  Step 3: CGU-PGSO            Step 4: All upstream + CGU-PGSO"
echo "  Step 4: CGU + fn PGSO       Step 5: All upstream + CGU+fn PGSO"
echo "  Step 5: brute-quick CGU     Step 6: All upstream + brute CGU"
echo "                                  (normal opt-levels only)"
echo "  (no equiv)                  Step 7: All upstream + brute CGU"
echo "                                  (incl. size-tweak levels)"
echo "  Step 6: fn-only PGSO        Step 8: All upstream + fn-only PGSO"
echo ""
echo "  Steps 7-10: extreme opts    (already folded into step 2)"
echo ""
echo "========================================================================="

# Total elapsed time (wall clock)
TOTAL_END_SECONDS=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END_SECONDS - TOTAL_START_SECONDS))
TOTAL_MIN=$((TOTAL_ELAPSED / 60))
TOTAL_SEC=$((TOTAL_ELAPSED % 60))
echo ""
echo "Total elapsed time: ${TOTAL_ELAPSED}s (${TOTAL_MIN}m ${TOTAL_SEC}s)"
