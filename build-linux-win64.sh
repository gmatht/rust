#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LINUX_HOST="x86_64-unknown-linux-gnu"
WINDOWS_HOST="x86_64-pc-windows-gnu"
PGO_DIR="$ROOT/build/pgo_data"
LINUX_OUT="$ROOT/saved/release-linux-x64"
WINDOWS_OUT="$ROOT/saved/release-win64"
WINDOWS_BUILD_DIR="${WINDOWS_BUILD_DIR:-$ROOT/build/windows-gnu}"

usage() {
    cat <<'EOF'
Usage: build-linux-win64.sh [--linux-only] [--windows-only]

Builds release compiler artifacts for Linux x64 and Win64 using the PGSO
lists in build/pgo_data/.

The Windows build targets x86_64-pc-windows-gnu (MinGW) and requires the
mingw-w64 cross-compiler (install: apt install gcc-mingw-w64-x86-64).

For native MSVC Windows builds, use the GitHub Actions workflow
(.github/workflows/optimized-rustc-release.yml) which runs on Windows runners.
EOF
}

linux_only=false
windows_only=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --linux-only)
            linux_only=true
            ;;
        --windows-only)
            windows_only=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [[ ! -f "$PGO_DIR/fn_opt_levels.txt" || ! -f "$PGO_DIR/cgu_opt_levels.txt" ]]; then
    echo "missing PGSO lists in $PGO_DIR" >&2
    exit 1
fi

if ! $windows_only; then
    echo "[1/2] Building Linux x64 compiler"
    RUSTFLAGS_NOT_BOOTSTRAP="-Z hot-cold-split -Z cgu-opt-levels=$PGO_DIR/cgu_opt_levels.txt -Z fn-opt-levels=$PGO_DIR/fn_opt_levels.txt" \
        python3 "$ROOT/x.py" build --stage 2 compiler/rustc library/std
    mkdir -p "$LINUX_OUT"
    cp "$ROOT/build/$LINUX_HOST/stage2/bin/rustc" "$LINUX_OUT/rustc"
    cp "$ROOT/build/$LINUX_HOST/stage2-rustc/$LINUX_HOST/release/librustc_driver.so" "$LINUX_OUT/"
    cat > "$LINUX_OUT/BUILD.txt" <<EOF
Built: $(date -u '+%Y-%m-%d %H:%M UTC')
Host: $LINUX_HOST
PGSO lists: $PGO_DIR/fn_opt_levels.txt, $PGO_DIR/cgu_opt_levels.txt
EOF
fi

if ! $linux_only; then
    echo "[2/2] Building Win64 compiler (MinGW)"
    if ! which x86_64-w64-mingw32-gcc &>/dev/null; then
        echo "missing MinGW cross-compiler (install: apt install gcc-mingw-w64-x86-64)" >&2
        exit 1
    fi

    mkdir -p "$WINDOWS_BUILD_DIR"
    env \
        CC_x86_64_pc_windows_gnu="x86_64-w64-mingw32-gcc" \
        CXX_x86_64_pc_windows_gnu="x86_64-w64-mingw32-g++" \
        AR_x86_64_pc_windows_gnu="x86_64-w64-mingw32-ar" \
        RUSTFLAGS_NOT_BOOTSTRAP="-Z hot-cold-split -Z cgu-opt-levels=$PGO_DIR/cgu_opt_levels.txt -Z fn-opt-levels=$PGO_DIR/fn_opt_levels.txt" \
        python3 "$ROOT/x.py" build --stage 2 --host "$WINDOWS_HOST" \
            --build-dir "$WINDOWS_BUILD_DIR" \
            --set 'llvm.link-shared=false' \
            compiler/rustc library/std

    mkdir -p "$WINDOWS_OUT"
    cp "$WINDOWS_BUILD_DIR/$WINDOWS_HOST/stage2/bin/rustc.exe" "$WINDOWS_OUT/rustc.exe" 2>/dev/null || true
    cp "$WINDOWS_BUILD_DIR/$WINDOWS_HOST/stage2/bin/rustc" "$WINDOWS_OUT/rustc" 2>/dev/null || true
    cp "$WINDOWS_BUILD_DIR/$WINDOWS_HOST/stage2/lib/rustlib/$WINDOWS_HOST/codegen-backends/"*.dll "$WINDOWS_OUT/" 2>/dev/null || true
    cat > "$WINDOWS_OUT/BUILD.txt" <<EOF
Built: $(date -u '+%Y-%m-%d %H:%M UTC')
Host: $WINDOWS_HOST (MinGW cross-compile)
Build dir: $WINDOWS_BUILD_DIR
PGSO lists: $PGO_DIR/fn_opt_levels.txt, $PGO_DIR/cgu_opt_levels.txt
Note: Native MSVC builds are produced by the GitHub Actions workflow.
EOF
fi
