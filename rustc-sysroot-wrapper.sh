#!/usr/bin/env bash
# rustc-sysroot-wrapper.sh — Wrapper for stage1 rustc that sets sysroot and
# library paths. Used by cargo-autosplit.sh as RUSTC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# Resolve the actual rustc binary (handle symlinks from rustup toolchains)
if [ -x /root/.rustup/toolchains/stage1/bin/rustc ]; then
    RUSTC="$(readlink -f /root/.rustup/toolchains/stage1/bin/rustc)"
elif [ -x "${SCRIPT_DIR}/build/host/stage1/bin/rustc" ]; then
    RUSTC="$(readlink -f "${SCRIPT_DIR}/build/host/stage1/bin/rustc")"
else
    echo "FATAL: no stage1 rustc found" >&2
    exit 1
fi

RUSTC_DIR="$(dirname "$(dirname "$RUSTC")")"
SYSROOT="$RUSTC_DIR"
DRIVER_DIR="$RUSTC_DIR/lib"
LLVM_DIR="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib/rustlib/x86_64-unknown-linux-gnu/lib"
LLVM_LIB="${SCRIPT_DIR}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib"

export LD_LIBRARY_PATH="$DRIVER_DIR:$LLVM_DIR:$LLVM_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$RUSTC" --sysroot="$SYSROOT" "$@" </dev/null
