#!/usr/bin/env bash
set -euo pipefail

TOOLCHAIN_NAME="pgso-almalinux8"
TOOLCHAIN_DIR="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$TOOLCHAIN_NAME"
RELEASE_URL="https://github.com/gmatht/rust/releases/download/v1.96.1-pgso"
TARBALL="$TOOLCHAIN_NAME.tar.gz"

ROOT="$(cd "$(dirname "$0")" && pwd)"

ensure_toolchain() {
    if [[ -x "$TOOLCHAIN_DIR/bin/rustc" ]]; then
        return 0
    fi
    echo "Downloading $TOOLCHAIN_NAME toolchain..." >&2
    mkdir -p "$TOOLCHAIN_DIR"
    if command -v curl &>/dev/null; then
        curl -sL "$RELEASE_URL/$TARBALL" -o "/tmp/$TARBALL"
    elif command -v wget &>/dev/null; then
        wget -q "$RELEASE_URL/$TARBALL" -O "/tmp/$TARBALL"
    else
        echo "error: need curl or wget" >&2
        exit 1
    fi
    tar xzf "/tmp/$TARBALL" -C "$TOOLCHAIN_DIR"
    rm "/tmp/$TARBALL"
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
