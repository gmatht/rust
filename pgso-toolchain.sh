#!/usr/bin/env bash
set -euo pipefail

NAME="pgso-almalinux8"
TOOLCHAIN_DIR="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$NAME"
BASE_URL="https://github.com/gmatht/rust/releases/download/v1.96.1-pgso"
TARBALL="$NAME.tar.gz"

# Ensure toolchain is installed
if [[ ! -x "$TOOLCHAIN_DIR/bin/rustc" ]]; then
    echo "Downloading $NAME toolchain..." >&2
    mkdir -p "$TOOLCHAIN_DIR"
    if command -v curl &>/dev/null; then
        curl -sL "$BASE_URL/$TARBALL" -o "/tmp/$TARBALL"
    elif command -v wget &>/dev/null; then
        wget -q "$BASE_URL/$TARBALL" -O "/tmp/$TARBALL"
    else
        echo "error: need curl or wget to download" >&2
        exit 1
    fi
    tar xzf "/tmp/$TARBALL" -C "$TOOLCHAIN_DIR"
    rm "/tmp/$TARBALL"
    # Link into rustup so cargo +$NAME works
    rustup toolchain link "$NAME" "$TOOLCHAIN_DIR" 2>/dev/null || true
    echo "Toolchain '$NAME' installed." >&2
fi

# If no subcommand, print path and exit
if [[ $# -eq 0 ]]; then
    echo "$TOOLCHAIN_DIR"
    exit 0
fi

# Forward subcommands: cargo, rustc, or anything else via cargo +toolchain
case "$1" in
    cargo)
        shift
        exec cargo "+$NAME" "$@"
        ;;
    rustc)
        shift
        exec "$TOOLCHAIN_DIR/bin/rustc" "$@"
        ;;
    *)
        exec cargo "+$NAME" "$@"
        ;;
esac