#!/usr/bin/env bash
# cargo-autosplit.sh — Build a Rust project with automatic hot/cold code splitting.
#
# Uses PGO profiling + rustc's -Z hot-cold-split to compile hot functions at
# O3 and cold functions at Oz, entirely automatically.
#
# Strategy (3-phase):
#   Phase 0 (warm-up):  Build at O3 + PGO generate (no splitting).  Run to
#                       collect initial PGO profiles.
#   Phase 0.5:           Merge Phase-0 profiles, extract hot function list.
#   Phase 1 (splitting): Build at O3 + PGO generate WITH -Z hot-cold-split
#                        using the hot-function-list from Phase 0.5.  This
#                        splits mixed CGUs into .o3 / .oz CGUs and produces
#                        PGO profiles under the split CGU structure.
#   Phase 1.5:           Merge Phase-1 profiles → merged.profdata.
#   Phase 2 (final):     Build at O3 + PGO use WITH -Z hot-cold-split using
#                        the SAME hot-function-list as Phase 1.  CGU structure
#                        is identical to Phase 1, so PGO hashes match.
#                        Per-CGU opt-level is applied during ThinLTO post-link
#                        only (via side-channel in rustc_session::config),
#                        so pre-link codegen is pure O3 for all CGUs.
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

# llvm-cxxfilt for demangling Rust symbol names from PGO profiles
if [ -x "${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/ci-llvm/bin/llvm-cxxfilt" ]; then
    CXXFILT="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/ci-llvm/bin/llvm-cxxfilt"
else
    CXXFILT="c++filt"
fi

# LLVM library paths for llvm-profdata
RUSTC_LLVM_DIR="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib/rustlib/x86_64-unknown-linux-gnu/lib"
RUSTC_LLVM_LIB="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib"

PGO_DIR=$(mktemp -d /tmp/cargo-autosplit-XXXXXX)
trap 'rm -rf "$PGO_DIR"' EXIT

export RUSTC="$RUSTC_WRAPPER_SCRIPT"
export RUSTC_WRAPPER=
unset CARGO_PROFILE_RELEASE_OPT_LEVEL
unset CARGO_PROFILE_RELEASE_LTO

# ============================================================
# Phase 0 — Warm-up: PGO profile generation at O3 (no splitting)
# ============================================================
echo "=== [cargo-autosplit] Phase 0 — warm-up PGO generation (O3, no splitting) ===" >&2
RUSTFLAGS="-C profile-generate=$PGO_DIR -C opt-level=3" cargo "$@"

# Run every built executable to collect Phase-0 profiles
REL_DIR="${CARGO_TARGET_DIR:-target}/release"
echo "=== [cargo-autosplit] Collecting Phase-0 profiles ===" >&2
# Remove build-script PGO profiles (generated during cargo build) so they don't
# contaminate the hot-function extraction. Only the binary's own profile data
# should be used to determine which functions are hot.
for f in "$PGO_DIR"/default_*.profraw; do
    [ -f "$f" ] && rm -f "$f"
done
for f in "$REL_DIR"/*; do
    if [ -f "$f" ] && [ -x "$f" ] && ! [ -d "$f" ]; then
        if file "$f" 2>/dev/null | grep -q 'ELF.*executable'; then
            echo "  running $f ..." >&2
            "$f" 3 >/dev/null 2>&1 || true
        fi
    fi
done

# Move Phase-0 raw profiles aside so Phase 1 doesn't overwrite them
for f in "$PGO_DIR"/default_*.profraw; do
    [ -f "$f" ] && mv "$f" "${f/default_/phase0_}"
done

# ============================================================
# Phase 0.5 — Merge Phase-0 profiles and extract hot function list
# ============================================================
echo "=== [cargo-autosplit] Merging Phase-0 profiles ===" >&2
LD_LIBRARY_PATH="$RUSTC_LLVM_DIR:$RUSTC_LLVM_LIB" $PROFDATA merge -o "$PGO_DIR/phase0_merged.profdata" "$PGO_DIR"/phase0_*.profraw 2>&1

echo "=== [cargo-autosplit] Extracting hot function list from Phase-0 profiles ===" >&2
LD_LIBRARY_PATH="$RUSTC_LLVM_DIR:$RUSTC_LLVM_LIB" "$PROFDATA" show --all-functions --counts "$PGO_DIR/phase0_merged.profdata" 2>&1 \
    | awk '
BEGIN {
    name = ""
    first_count = 0
    max_count = 0
}
# Function name lines: start with 2 spaces, end with :
/^  / && /:$/ {
    if ($1 == "Counters:" || $1 == "Hash:") next
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
' | $CXXFILT 2>/dev/null | sort -u > "$PGO_DIR/hot_functions.txt"

NUM_HOT=$(wc -l < "$PGO_DIR/hot_functions.txt")
echo "  Found $NUM_HOT hot functions (threshold >1% of max)" >&2
if [ "$NUM_HOT" -gt 0 ]; then
    echo "  Hot functions ($NUM_HOT):" >&2
    head -5 "$PGO_DIR/hot_functions.txt" | cat -v >&2
    if [ "$NUM_HOT" -gt 5 ]; then
        echo "  ... and $((NUM_HOT - 5)) more" >&2
    fi
fi

rm -f "$REL_DIR/.cargo-lock" "$REL_DIR/.cargo-ok" 2>/dev/null || true

HOT_COLD_FLAGS=""
if [ "$NUM_HOT" -gt 0 ]; then
    HOT_COLD_FLAGS="-Z hot-cold-split -Z hot-function-list=$PGO_DIR/hot_functions.txt"
    echo "=== [cargo-autosplit] Hot function list has $NUM_HOT entries, enabling CGU splitting ===" >&2
else
    echo "=== [cargo-autosplit] No hot functions found, skipping CGU splitting ===" >&2
fi

# Clean ALL build artifacts to force cargo to recompile EVERY crate with Phase 1 flags
# (dependencies cached from Phase 0 without -Z hot-cold-split must be rebuilt)
cargo clean 2>/dev/null || true

# ============================================================
# Phase 1 — PGO profile generation with hot/cold CGU splitting
# ============================================================
echo "=== [cargo-autosplit] Phase 1 — PGO generation with hot-cold-split ===" >&2
RUSTFLAGS="-C profile-generate=$PGO_DIR -C opt-level=3 $HOT_COLD_FLAGS" cargo "$@"

# Run every built executable to collect Phase-1 profiles
echo "=== [cargo-autosplit] Collecting Phase-1 profiles ===" >&2
for f in "$REL_DIR"/*; do
    if [ -f "$f" ] && [ -x "$f" ] && ! [ -d "$f" ]; then
        if file "$f" 2>/dev/null | grep -q 'ELF.*executable'; then
            echo "  running $f ..." >&2
            "$f" 15 >/dev/null 2>&1 || true
        fi
    fi
done

# Move Phase-1 raw profiles aside
for f in "$PGO_DIR"/default_*.profraw; do
    [ -f "$f" ] && mv "$f" "${f/default_/phase1_}"
done

rm -f "$REL_DIR/.cargo-lock" "$REL_DIR/.cargo-ok" 2>/dev/null || true

# ============================================================
# Phase 1.5 — Merge Phase-1 profiles for final PGO use
# ============================================================
echo "=== [cargo-autosplit] Merging Phase-1 profiles ===" >&2
LD_LIBRARY_PATH="$RUSTC_LLVM_DIR:$RUSTC_LLVM_LIB" $PROFDATA merge -o "$PGO_DIR/merged.profdata" "$PGO_DIR"/phase1_*.profraw 2>&1

cargo clean 2>/dev/null || true

# ============================================================
# Phase 2 — Final build with PGO use + hot/cold CGU splitting
# ============================================================
echo "=== [cargo-autosplit] Phase 2 — build (PGO use + hot-cold-split) ===" >&2
# PGO profile-use provides function-level hot/cold annotation to LLVM's
# optimizer, improving performance for hot functions.  The per-CGU opt-level
# side channel (from partitioning.rs) ensures cold CGUs get SizeMin (Oz)
# and hot CGUs get Aggressive (O3) during ThinLTO post-link, regardless
# of the global opt-level.  The global opt-level is set to O3 to allow
# PGO-guided inlining and optimization at the module level.
RUSTFLAGS="-C profile-use=$PGO_DIR/merged.profdata -C opt-level=3 $HOT_COLD_FLAGS" cargo "$@"

# Aggressively strip the output binary to remove any remaining non-essential
# sections (e.g., .note, .comment, .relro_padding) that Cargo's
# profile.release.strip may leave behind.
STRIP_BIN="$PROFDATA"
STRIP_BIN="${STRIP_BIN/llvm-profdata/llvm-strip}"
for f in "$REL_DIR"/*; do
    if [ -f "$f" ] && [ -x "$f" ] && ! [ -d "$f" ]; then
        if file "$f" 2>/dev/null | grep -q 'ELF.*executable'; then
            if [ -x "$STRIP_BIN" ]; then
                "$STRIP_BIN" --strip-all "$f" 2>/dev/null || true
            else
                strip "$f" 2>/dev/null || true
            fi
        fi
    fi
done

echo "=== [cargo-autosplit] Done ===" >&2
