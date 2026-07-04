#!/usr/bin/env bash
set -euo pipefail

TOOLCHAIN_NAME="pgso-almalinux8"
TOOLCHAIN_DIR="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$TOOLCHAIN_NAME"
RELEASE_URL="https://github.com/gmatht/rust/releases/download/v1.96.1-pgso"
TARBALL="release-almalinux8.tar.gz"
STOCK_TC="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/1.96.1-x86_64-unknown-linux-gnu"

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
    mkdir -p "$TOOLCHAIN_DIR" "$TOOLCHAIN_DIR/bin" "$TOOLCHAIN_DIR/lib"
    if command -v curl &>/dev/null; then
        curl -sL "$RELEASE_URL/$TARBALL" -o "/tmp/$TARBALL"
    elif command -v wget &>/dev/null; then
        wget -q "$RELEASE_URL/$TARBALL" -O "/tmp/$TARBALL"
    else
        echo "error: need curl or wget" >&2
        exit 1
    fi

    # Extract to temp, then place files correctly
    mkdir -p "/tmp/pgso-extract"
    tar xzf "/tmp/$TARBALL" -C "/tmp/pgso-extract"
    rm "/tmp/$TARBALL"
    cp "/tmp/pgso-extract/rustc" "$TOOLCHAIN_DIR/bin/rustc"
    cp "/tmp/pgso-extract/librustc_driver.so" "$TOOLCHAIN_DIR/lib/"
    # rustc wrapper links librustc_driver-<hash>.so; get hash from binary
    DRV_NEEDED=$(readelf -d "$TOOLCHAIN_DIR/bin/rustc" 2>/dev/null | awk '/NEEDED.*librustc_driver/{print $5}' | tr -d '[]' || true)
    if [[ -n "$DRV_NEEDED" ]] && [[ "$DRV_NEEDED" != "librustc_driver.so" ]]; then
        ln -sf "librustc_driver.so" "$TOOLCHAIN_DIR/lib/$DRV_NEEDED"
    fi
    rm -rf "/tmp/pgso-extract"

    # Symlink missing components from stock 1.96.1
    ln -sf "$STOCK_TC/bin/cargo" "$TOOLCHAIN_DIR/bin/cargo"
    ln -sf "$STOCK_TC/lib/libLLVM-22-rust-1.96.1-stable.so" "$TOOLCHAIN_DIR/lib/"
    ln -sf "$STOCK_TC/lib/libLLVM.so.22.1-rust-1.96.1-stable" "$TOOLCHAIN_DIR/lib/"
    ln -sfn "$STOCK_TC/lib/rustlib" "$TOOLCHAIN_DIR/lib/rustlib"

    rustup toolchain link "$TOOLCHAIN_NAME" "$TOOLCHAIN_DIR" 2>/dev/null || true
    echo "Installed." >&2
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
    COUNTS_FILE="$PGO_DIR/function_counts.txt"
    mkdir -p "$PGO_DIR" "$TRAIN_DIR"
    printf '%s\n' "$TRAIN_CMD" > "$TRAIN_DIR/train.cmd"
    echo "[1/2] Running training command"
    pushd "$WORKDIR" >/dev/null
    RUSTC="$TOOLCHAIN_DIR/bin/rustc" CARGO="cargo +$TOOLCHAIN_NAME" \
    RUSTFLAGS="${RUSTFLAGS:-} -Cprofile-generate=$PGO_DIR -Zfunction-block-counts=$COUNTS_FILE" \
        bash -lc "$TRAIN_CMD" \
        >"$TRAIN_DIR/train.stdout" 2>"$TRAIN_DIR/train.stderr"
    popd >/dev/null
    echo "[2/2] Merging profiles"
    llvm_profdata="$(command -v llvm-profdata || true)"
    if [[ -z "$llvm_profdata" ]]; then
        llvm_profdata="$TOOLCHAIN_DIR/lib/llvm-bin/bin/llvm-profdata"
        [[ -x "$llvm_profdata" ]] || { echo "llvm-profdata not found" >&2; exit 1; }
    fi
    profiles=("$PGO_DIR"/*.profraw)
    "$llvm_profdata" merge -o "$OUT_DIR/merged.profdata" "${profiles[@]}"
    [[ -s "$COUNTS_FILE" ]] || { echo "function_counts.txt not written" >&2; exit 1; }
    echo "saved to $OUT_DIR"
    exit 0
fi

# --- Default mode: use the PGSO toolchain ---
ensure_toolchain
if [[ $# -eq 0 ]]; then
    echo "$TOOLCHAIN_DIR"
    exit 0
fi
exec cargo "+$TOOLCHAIN_NAME" "$@"
