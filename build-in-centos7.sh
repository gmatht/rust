#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE="ghcr.io/rust-lang/centos:7"
OUT_DIR="$ROOT/saved/release-centos7"

mkdir -p "$OUT_DIR"

echo "Staging PGSO lists into container-accessible path..."
PGO_DIR_CONTAINER="/tmp/pgo_data"
mkdir -p "$PGO_DIR_CONTAINER"
cp "$ROOT/build/pgo_data/fn_opt_levels.txt" "$PGO_DIR_CONTAINER/"
cp "$ROOT/build/pgo_data/cgu_opt_levels.txt" "$PGO_DIR_CONTAINER/"

echo "Building inside CentOS 7 container..."
BUILD_DIR="/tmp/centos7-build-$$"
mkdir -p "$BUILD_DIR"

docker run --rm -i \
    -v "$ROOT:/build/rust:ro" \
    -v "$PGO_DIR_CONTAINER:/pgo_data:ro" \
    -v "$BUILD_DIR:/build/output" \
    -w /build/rust \
    "$IMAGE" \
    bash -c '
set -eux
export CC=clang CXX=clang++
export PATH="/rustroot/bin:$PATH"
export LD_LIBRARY_PATH="/rustroot/lib64:/rustroot/lib"
export RUSTFLAGS_NOT_BOOTSTRAP="-Z hot-cold-split -Z cgu-opt-levels=/pgo_data/cgu_opt_levels.txt -Z fn-opt-levels=/pgo_data/fn_opt_levels.txt"

python3 x.py build --stage 2 compiler/rustc library/std --build-dir /build/output
'

echo "Copying artifacts..."
cp "$BUILD_DIR/x86_64-unknown-linux-gnu/stage2/bin/rustc" "$OUT_DIR/rustc"
cp "$BUILD_DIR/x86_64-unknown-linux-gnu/stage2-rustc/x86_64-unknown-linux-gnu/release/librustc_driver.so" "$OUT_DIR/"

cat > "$OUT_DIR/BUILD.txt" <<EOF
Built: $(date -u '+%Y-%m-%d %H:%M UTC')
Image: $IMAGE
Host: x86_64-unknown-linux-gnu (CentOS 7 compat)
PGSO lists: /pgo_data/fn_opt_levels.txt, /pgo_data/cgu_opt_levels.txt
EOF

echo "saved to $OUT_DIR"
