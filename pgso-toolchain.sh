#!/usr/bin/env bash
set -euo pipefail

NAME="pgso-almalinux8"
TOOLCHAIN_DIR="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$NAME"
BASE_URL="https://github.com/gmatht/rust/raw/stable-pgso/dist"

if [[ -x "$TOOLCHAIN_DIR/bin/rustc" ]]; then
    echo "Toolchain '$NAME' already installed at $TOOLCHAIN_DIR"
    exit 0
fi

echo "Downloading $NAME toolchain..."
mkdir -p "$TOOLCHAIN_DIR"
TARBALL="$NAME.tar.gz"

# Try to download from GitHub raw
if command -v curl &>/dev/null; then
    curl -sL "$BASE_URL/$TARBALL" -o "/tmp/$TARBALL"
elif command -v wget &>/dev/null; then
    wget -q "$BASE_URL/$TARBALL" -O "/tmp/$TARBALL"
else
    echo "error: need curl or wget to download" >&2
    exit 1
fi

echo "Extracting to $TOOLCHAIN_DIR..."
tar xzf "/tmp/$TARBALL" -C "$TOOLCHAIN_DIR"
rm "/tmp/$TARBALL"

echo "Toolchain '$NAME' installed."
echo "Use: rustup toolchain link $NAME '$TOOLCHAIN_DIR'"
echo "Or:  cargo +$NAME build"
