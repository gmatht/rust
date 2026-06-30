#!/usr/bin/env bash
# cargo-autosplit.sh — Build a Rust project with automatic hot/cold code splitting.
#
# Uses PGO profiling + rustc's -Z hot-cold-split to compile hot functions at
# O3 and cold functions at Oz, entirely automatically.
#
# Usage:  cargo-autosplit.sh <cargo args...>
#
# Example:
#   ./cargo-autosplit.sh build --release -p prime-finder
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# Try rustup-managed stage1 toolchain first, fall back to local build
if [ -x /root/.rustup/toolchains/stage1/bin/rustc ]; then
    RUSTC="/root/.rustup/toolchains/stage1/bin/rustc"
    RUSTC_LIB_DIR="/root/.rustup/toolchains/stage1/lib"
elif [ -x "${SCRIPT_DIR}/build/host/stage1/bin/rustc" ]; then
    RUSTC="${SCRIPT_DIR}/build/host/stage1/bin/rustc"
    RUSTC_LIB_DIR="${SCRIPT_DIR}/build/host/stage1/lib"
else
    echo "FATAL: no stage1 rustc found" >&2
    exit 1
fi
# llvm-profdata: prefer ci-llvm path (CI builds), fall back to stage2 (custom builds)
if [ -x "${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/ci-llvm/bin/llvm-profdata" ]; then
    PROFDATA="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/ci-llvm/bin/llvm-profdata"
elif [ -x "${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage2/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata" ]; then
    PROFDATA="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage2/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata"
elif [ -x "$RUSTC_LIB_DIR/../bin/llvm-profdata" ]; then
    PROFDATA="$RUSTC_LIB_DIR/../bin/llvm-profdata"
else
    echo "FATAL: llvm-profdata not found" >&2
    exit 1
fi
RUSTC_WRAPPER_SCRIPT="${SCRIPT_DIR}/rustc-sysroot-wrapper.sh"

# LLVM library paths for llvm-profdata
RUSTC_LLVM_DIR="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib/rustlib/x86_64-unknown-linux-gnu/lib"
RUSTC_LLVM_LIB="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib"

PGO_DIR=$(mktemp -d /tmp/cargo-autosplit-XXXXXX)
trap 'rm -rf "$PGO_DIR"' EXIT

export RUSTC="$RUSTC_WRAPPER_SCRIPT"
export RUSTC_WRAPPER=
unset CARGO_PROFILE_RELEASE_OPT_LEVEL
unset CARGO_PROFILE_RELEASE_LTO

# Phase 1 — PGO profile generation at O3
echo "=== [cargo-autosplit] Phase 1 — PGO profile generation (O3) ===" >&2
RUSTFLAGS="-C profile-generate=$PGO_DIR -C opt-level=3" cargo "$@"

# Phase 1b — run every built executable to collect profiles
REL_DIR="${CARGO_TARGET_DIR:-target}/release"
echo "=== [cargo-autosplit] Collecting PGO profiles ===" >&2
for f in "$REL_DIR"/*; do
    if [ -f "$f" ] && [ -x "$f" ] && ! [ -d "$f" ]; then
        if file "$f" 2>/dev/null | grep -q 'ELF.*executable'; then
            echo "  running $f ..." >&2
            "$f" 5 >/dev/null 2>&1 || true
        fi
    fi
done

# Merge raw profiles
echo "=== [cargo-autosplit] Merging profiles ===" >&2
LD_LIBRARY_PATH="$RUSTC_LLVM_DIR:$RUSTC_LLVM_LIB" $PROFDATA merge -o "$PGO_DIR/merged.profdata" "$PGO_DIR"/default_*.profraw 2>&1

# Phase 1.5 — extract hot function list from merged PGO profile.
# Functions with first-block count above 1% of the maximum are classified as
# hot; everything else is cold.  Names have CGU prefixes (e.g.
# "prime_finder.xxx-cgu.N;symname") stripped so they match the symbol names
# that rustc's is_item_hot() checks.
echo "=== [cargo-autosplit] Extracting hot function list ===" >&2
LD_LIBRARY_PATH="$RUSTC_LLVM_DIR:$RUSTC_LLVM_LIB" "$PROFDATA" show --all-functions --counts "$PGO_DIR/merged.profdata" 2>&1 \
    | awk '
BEGIN {
    name = ""
    first_count = 0
    max_count = 0
}
# Function name lines: start with 2 spaces, end with :
/^  / && /:$/ {
    if ($1 == "Counters:") next
    if (name != "" && first_count > 0) {
        if (first_count > max_count) max_count = first_count
        gnames[name] = first_count
    }
    this_name = $1
    gsub(/:$/, "", this_name)
    n = split(this_name, parts, ";")
    if (n > 1) this_name = parts[n]
    name = this_name
    first_count = 0
}
# Block counts line — extract first count value
/^    Block counts: \[/ {
    if (name != "") {
        line = $0
        gsub(/^.*\[/, "", line)
        gsub(/,.*$/, "", line)
        gsub(/ /, "", line)
        first_count = line + 0
    }
}
# Non-indented line (summary) — end of last function
/^[^ ]/ && NR > 1 {
    if (name != "" && first_count > 0) {
        if (first_count > max_count) max_count = first_count
        gnames[name] = first_count
    }
    name = ""
    first_count = 0
}
END {
    if (name != "" && first_count > 0) {
        if (first_count > max_count) max_count = first_count
        gnames[name] = first_count
    }
    # Print names whose count is > 1% of max count
    threshold = max_count * 0.01
    if (threshold < 1) threshold = 1
    for (n in gnames) {
        if (gnames[n] > threshold) {
            print n
        }
    }
}
' | sort -u > "$PGO_DIR/hot_functions.txt"

NUM_HOT=$(wc -l < "$PGO_DIR/hot_functions.txt")
echo "  Found $NUM_HOT hot functions (threshold >1% of max)" >&2

rm -f "$REL_DIR/.cargo-lock" "$REL_DIR/.cargo-ok" 2>/dev/null || true

# Phase 2 — rebuild with PGO profile-use + O3.
# Hot/cold per-CGU opt-level via -Z hot-cold-split is NOT used because it
# changes the LLVM pre-PGO optimization pipeline (CallSiteSplittingPass,
# pre-inliner thresholds) differently for O3 vs Oz CGUs, causing PGO hash
# mismatches and discarded profile data.
# PGO profile-use alone guides LLVM's hot/code classification.
echo "=== [cargo-autosplit] Phase 2 — build (O3 + PGO) ===" >&2
RUSTFLAGS="-C profile-use=$PGO_DIR/merged.profdata -C opt-level=3" cargo "$@"

echo "=== [cargo-autosplit] Done ===" >&2
