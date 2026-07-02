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
RUSTC="${SCRIPT_DIR}/build/host/stage1/bin/rustc"
SYSROOT="${SCRIPT_DIR}/build/host/stage1"
# llvm-profdata: prefer ci-llvm path (CI builds), fall back to stage2 (custom builds)
if [ -x "${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/ci-llvm/bin/llvm-profdata" ]; then
    PROFDATA="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/ci-llvm/bin/llvm-profdata"
else
    PROFDATA="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage2/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata"
fi
RUSTC_WRAPPER_SCRIPT="${SCRIPT_DIR}/rustc-sysroot-wrapper.sh"
RUSTC_DRIVER_DIR="$(dirname "$(readlink -f "$RUSTC")")/deps"
RUSTC_LLVM_DIR="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib/rustlib/x86_64-unknown-linux-gnu/lib"
RUSTC_LLVM_LIB="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib"
# Ensure .rmeta/.rlib files are in the sysroot (x.py build --stage 1 library
# puts them in stage1-std/dist/deps/ but not in the sysroot).
RUSTC_STD_DEPS="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage1-std/x86_64-unknown-linux-gnu/dist/deps"
if [ -d "$RUSTC_STD_DEPS" ]; then
    for ext in rmeta rlib; do
        for f in "$RUSTC_STD_DEPS"/*.$ext; do
            bn=$(basename "$f")
            if [ ! -f "$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib/$bn" ]; then
                cp -n "$f" "$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib/"
            fi
        done
    done
fi
# Copy self-contained linker (rust-lld) and gcc-ld wrappers from stage0-sysroot
SYSROOT_BIN="$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/bin"
STAGE0_BIN="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib/rustlib/x86_64-unknown-linux-gnu/bin"
if [ -d "$STAGE0_BIN" ] && [ ! -f "$SYSROOT_BIN/rust-lld" ]; then
    mkdir -p "$SYSROOT_BIN"
    cp -r "$STAGE0_BIN"/* "$SYSROOT_BIN/"
fi

[ -x "$RUSTC" ] || { echo "FATAL: rustc not found at $RUSTC" >&2; exit 1; }
[ -d "$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib" ] || { echo "FATAL: sysroot missing std at $SYSROOT" >&2; exit 1; }
[ -x "$PROFDATA" ] || { echo "FATAL: llvm-profdata not found at $PROFDATA" >&2; exit 1; }

# Create a wrapper that injects --sysroot so cargo always finds std
if [ ! -x "$RUSTC_WRAPPER_SCRIPT" ]; then
    cat > "$RUSTC_WRAPPER_SCRIPT" <<-RUSTC_EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$RUSTC_DRIVER_DIR:$RUSTC_LLVM_DIR:$RUSTC_LLVM_LIB:\${LD_LIBRARY_PATH:-}"
exec "$RUSTC" --sysroot="$SYSROOT" "\$@"
RUSTC_EOF
    chmod +x "$RUSTC_WRAPPER_SCRIPT"
fi

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
echo "=== [cargo-autosplit] Collecting PGO profiles ===" >&2
for f in target/release/*; do
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
    max_block = 0
    global_max = 0
}
# Function name lines: start with 2 spaces, end with :
/^  / && /:$/ {
    if ($1 == "Counters:") next
    if (name != "" && max_block > 0) {
        if (max_block > global_max) global_max = max_block
        gnames[name] = max_block
    }
    this_name = $1
    gsub(/:$/, "", this_name)
    n = split(this_name, parts, ";")
    if (n > 1) this_name = parts[n]
    name = this_name
    max_block = 0
}
# Block counts line — extract max count value across all blocks
/^    Block counts: \[/ {
    if (name != "") {
        line = $0
        gsub(/^.*\[/, "", line)
        gsub(/].*$/, "", line)
        gsub(/ /, "", line)
        split(line, counts, ",")
        for (i in counts) {
            if (counts[i] + 0 > max_block) max_block = counts[i] + 0
        }
    }
}
# Non-indented line (summary) — end of last function
/^[^ ]/ && NR > 1 {
    if (name != "" && max_block > 0) {
        if (max_block > global_max) global_max = max_block
        gnames[name] = max_block
    }
    name = ""
    max_block = 0
}
END {
    if (name != "" && max_block > 0) {
        if (max_block > global_max) global_max = max_block
        gnames[name] = max_block
    }
    # Print names whose max block count is > 1% of global max
    threshold = global_max * 0.01
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

rm -f target/release/.cargo-lock target/release/.cargo-ok 2>/dev/null || true

# Phase 2 — rebuild with profile use + hot-cold-split.
# Global Oz compiles all code for size by default. Per-CGU overrides in
# partitioning.rs set hot CGUs to Aggressive (O3) and cold CGUs to
# SizeMin (Oz). Dependencies inherit the global Oz, matching the baseline.
# Visibility is overridden to Default when hot-cold-split is active so
# ThinLTO can freely import functions between Oz and O3 CGUs.
# ThinLTO post-link: hot CGUs O3, cold CGUs SizeMin, deps SizeMin.
echo "=== [cargo-autosplit] Phase 2 — hot-cold-split build (hot=O3, cold=Oz, deps=Oz) ===" >&2
RUSTFLAGS="-C profile-use=$PGO_DIR/merged.profdata -C opt-level=z -Z hot-cold-split -Z hot-function-list=$PGO_DIR/hot_functions.txt" cargo "$@"

echo "=== [cargo-autosplit] Done ===" >&2
