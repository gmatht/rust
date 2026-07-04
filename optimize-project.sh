#!/usr/bin/env bash
set -euo pipefail

TOOLCHAIN_NAME="pgso-almalinux8"
TOOLCHAIN_DIR="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$TOOLCHAIN_NAME"
RELEASE_URL="https://github.com/gmatht/rust/releases/download/v1.96.1-pgso"
TARBALL="release-almalinux8.tar.gz"
STOCK_TC="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/1.96.1-x86_64-unknown-linux-gnu"
NIGHTLY_TC="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/nightly-x86_64-unknown-linux-gnu"

ROOT="$(cd "$(dirname "$0")" && pwd)"

ensure_stock() {
    if [[ ! -x "$STOCK_TC/bin/rustc" ]]; then
        echo "Stock 1.96.1 not found at $STOCK_TC" >&2
        echo "Install: rustup toolchain install 1.96.1-x86_64-unknown-linux-gnu" >&2
        exit 1
    fi
}

ensure_toolchain() {
    if [[ -x "$TOOLCHAIN_DIR/bin/rustc" ]]; then
        return 0
    fi
    ensure_stock

    echo "Downloading $TOOLCHAIN_NAME toolchain..." >&2
    EXTRACT="/tmp/pgso-extract-$$"
    mkdir -p "$EXTRACT" "$TOOLCHAIN_DIR/bin" "$TOOLCHAIN_DIR/lib/rustlib"
    if command -v curl &>/dev/null; then
        curl -sL "$RELEASE_URL/$TARBALL" -o "/tmp/$TARBALL"
    elif command -v wget &>/dev/null; then
        wget -q "$RELEASE_URL/$TARBALL" -O "/tmp/$TARBALL"
    else
        echo "error: need curl or wget" >&2
        exit 1
    fi

    tar xzf "/tmp/$TARBALL" -C "$EXTRACT"
    rm "/tmp/$TARBALL"

    # Copy compiler and driver
    cp "$EXTRACT/bin/rustc" "$TOOLCHAIN_DIR/bin/rustc"
    for f in "$EXTRACT/lib/"*; do
        bn=$(basename "$f")
        if [[ "$bn" == librustc_driver-* ]]; then
            cp "$f" "$TOOLCHAIN_DIR/lib/$bn"
            ln -sf "$bn" "$TOOLCHAIN_DIR/lib/librustc_driver.so"
        fi
    done

    # Copy host stdlib for build scripts
    if [[ -d "$EXTRACT/lib/rustlib/x86_64-unknown-linux-gnu" ]]; then
        cp -r "$EXTRACT/lib/rustlib/x86_64-unknown-linux-gnu" "$TOOLCHAIN_DIR/lib/rustlib/"
    fi
    rm -rf "$EXTRACT"

    # Symlink rust-src from stock 1.96.1 for -Z build-std
    ln -sfn "$STOCK_TC/lib/rustlib/src" "$TOOLCHAIN_DIR/lib/rustlib/src"

    # Symlink LLVM and cargo from stock
    if [[ -x "$NIGHTLY_TC/bin/cargo" ]]; then
        ln -sf "$NIGHTLY_TC/bin/cargo" "$TOOLCHAIN_DIR/bin/cargo"
    else
        ln -sf "$STOCK_TC/bin/cargo" "$TOOLCHAIN_DIR/bin/cargo"
    fi
    ln -sf "$STOCK_TC/lib/libLLVM-22-rust-1.96.1-stable.so" "$TOOLCHAIN_DIR/lib/"
    ln -sf "$STOCK_TC/lib/libLLVM.so.22.1-rust-1.96.1-stable" "$TOOLCHAIN_DIR/lib/"

    echo "Installed. Use: cargo +$TOOLCHAIN_NAME -Z build-std build --release" >&2
}

# --- Profile mode: --train-cmd ---
if [[ "${1:-}" == "--train-cmd" ]]; then
    ensure_toolchain
    shift
    TRAIN_CMD="$1"
    shift || true
    WORKDIR="${1:-.}"
    shift 2>/dev/null || true
    OUT_DIR="$ROOT/saved/optimized_project"
    PGO_DIR="$OUT_DIR/pgo"
    TRAIN_DIR="$OUT_DIR/train"
    mkdir -p "$PGO_DIR" "$TRAIN_DIR"
    printf '%s\n' "$TRAIN_CMD" > "$TRAIN_DIR/train.cmd"
    echo "[1/3] Running training command"
    pushd "$WORKDIR" >/dev/null
    RUSTC="$TOOLCHAIN_DIR/bin/rustc" CARGO="cargo +$TOOLCHAIN_NAME" \
    RUSTFLAGS="${RUSTFLAGS:-} -Cprofile-generate=$PGO_DIR" \
        bash -lc "$TRAIN_CMD" \
        >"$TRAIN_DIR/train.stdout" 2>"$TRAIN_DIR/train.stderr"
    popd >/dev/null
    echo "[2/3] Merging profiles"
    llvm_profdata="$(command -v llvm-profdata || true)"
    if [[ -z "$llvm_profdata" ]]; then
        llvm_profdata=$(find /root/.rustup/toolchains/ -name llvm-profdata 2>/dev/null | head -1)
        [[ -x "$llvm_profdata" ]] || { echo "llvm-profdata not found" >&2; exit 1; }
    fi
    profiles=("$PGO_DIR"/*.profraw)
    "$llvm_profdata" merge -o "$OUT_DIR/merged.profdata" "${profiles[@]}"
    echo "[3/3] Generating opt-level lists"
    python3 "$ROOT/src/tools/generate_opt_levels.py" --profdata "$OUT_DIR/merged.profdata" --llvm-profdata "$llvm_profdata"
    echo "saved to $OUT_DIR"
    exit 0
fi

# --- Default mode: use the PGSO toolchain with -Z build-std ---
ensure_toolchain
if [[ $# -eq 0 ]]; then
    echo "$TOOLCHAIN_DIR"
    exit 0
fi
exec cargo "+$TOOLCHAIN_NAME" -Z build-std "$@"
