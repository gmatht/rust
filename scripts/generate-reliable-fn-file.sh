#!/usr/bin/env bash
# generate-reliable-fn-file.sh
#
# Generates an fn_opt_levels file where every function name is guaranteed
# to match at least one crate in the build.  Uses a patched compiler that
# appends to the unmatched+matched logs instead of overwriting them.
#
# Usage:
#   ./scripts/generate-reliable-fn-file.sh [--build-dir <dir>]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/build-patched"
OLD_FN_FILE="${ROOT}/build/pgo_data/fn_opt_levels_1x.txt"
NEW_FN_FILE="${ROOT}/build/pgo_data/fn_opt_levels_1x_reliable.txt"

# Step 1: Check patched compiler exists
PATCHED_RUSTC="${BUILD_DIR}/x86_64-unknown-linux-gnu/stage2/bin/rustc"
if [ ! -x "$PATCHED_RUSTC" ]; then
    echo "ERROR: Patched stage2 compiler not found at $PATCHED_RUSTC"
    echo "Run 'python3 x.py build --stage 2 --build-dir build-patched -j 4' first."
    exit 1
fi
echo "Using patched compiler: $($PATCHED_RUSTC --version 2>/dev/null)"

# Step 2: Clean previous capture logs
rm -f "${OLD_FN_FILE}.fn_opt_levels.matched.log"
rm -f "${OLD_FN_FILE}.fn_opt_levels.unmatched.log"

echo "Running capture build with patched compiler..."
cd "$ROOT"

# Use the original fn file for the capture build so we capture
# both matches (from the original profiling data) and defaulting functions.
# We build --stage 2 using the patched stage2 as the build compiler.
RUSTFLAGS="-Z human-readable-cgu-names -C strip=symbols -Z hot-cold-split \
    -Z fn-opt-levels=${OLD_FN_FILE} -Z fn-opt-level-default=Oz"

python3 x.py build --stage 2 compiler/rustc library/std \
    --build-dir "${BUILD_DIR}-capture" -j 4 \
    --set build.rustc="${PATCHED_RUSTC}" \
    2>&1 | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush() }' | tee /tmp/capture-build.log

echo ""
echo "=== Capture build complete ==="

# Step 3: Parse matched log
MATCHED_LOG="${OLD_FN_FILE}.fn_opt_levels.matched.log"
UNMATCHED_LOG="${OLD_FN_FILE}.fn_opt_levels.unmatched.log"

if [ ! -f "$MATCHED_LOG" ]; then
    echo "ERROR: matched log not found at $MATCHED_LOG"
    exit 1
fi

echo "Parsing matched entries..."
# Collect unique function_name + opt_level pairs from matched log
# Lines have format: "func_name O3" or "# crate: cratename"
grep -v '^#' "$MATCHED_LOG" | sort -u > /tmp/matched_entries.txt
echo "  Found $(wc -l < /tmp/matched_entries.txt) matched entries"

echo "Parsing unmatched log for verification..."
# "fn defaulting: func_name Oz" lines show functions that defaulted
grep "^fn defaulting:" "$UNMATCHED_LOG" 2>/dev/null | \
    sed 's/^fn defaulting: //' | sort -u > /tmp/defaulting_entries.txt
echo "  Found $(wc -l < /tmp/defaulting_entries.txt) defaulting entries"

# Step 4: Verify all matched entries are NOT in defaulting list
echo "Verifying matched entries are not defaulting..."
comm -12 /tmp/matched_entries.txt /tmp/defaulting_entries.txt > /tmp/false_positives.txt || true
if [ -s /tmp/false_positives.txt ]; then
    echo "  WARNING: $(wc -l < /tmp/false_positives.txt) entries appear in BOTH matched and defaulting!"
    echo "  These may be duplicates across crates."
    # Keep them anyway (they matched somewhere)
fi

# Step 5: Generate new fn file
echo "Generating ${NEW_FN_FILE}..."
# Write header
echo "# Reliable fn_opt_levels file generated $(date)" > "$NEW_FN_FILE"
echo "# Each function name is verified to match at least one crate." >> "$NEW_FN_FILE"
echo "# Source: $(basename "$OLD_FN_FILE") with profiling-based opt levels." >> "$NEW_FN_FILE"
echo "" >> "$NEW_FN_FILE"

# Write matched entries (with profiling-based opt levels)
cat /tmp/matched_entries.txt >> "$NEW_FN_FILE"

total_entries=$(wc -l < /tmp/matched_entries.txt)
echo "  Wrote $total_entries entries"
echo ""
echo "=== Summary ==="
echo "  Total fn file entries: $total_entries"
echo "  All guaranteed to match at least one crate."
echo "  File: ${NEW_FN_FILE}"
echo ""
echo "To use: set FN_FILE_1X=\"${NEW_FN_FILE}\" in sizewalk-upstream-first.sh"
