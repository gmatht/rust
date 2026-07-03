#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LINUX_HOST="x86_64-unknown-linux-gnu"
WINDOWS_HOST="x86_64-pc-windows-msvc"
PGO_DIR="$ROOT/build/pgo_data"
LINUX_OUT="$ROOT/saved/release-linux-x64"
WINDOWS_OUT="$ROOT/saved/release-win64"
WINDOWS_CARGO="${WINDOWS_CARGO:-/mnt/c/Users/s_pam/.cargo/bin/cargo.exe}"
WINDOWS_RUSTC="${WINDOWS_RUSTC:-/mnt/c/Users/s_pam/.cargo/bin/rustc.exe}"
WINDOWS_BUILD_DIR="${WINDOWS_BUILD_DIR:-/mnt/d/tmp/rust-pgso-win64-build}"

usage() {
    cat <<'EOF'
Usage: build-linux-win64.sh [--linux-only] [--windows-only]

Builds release compiler artifacts for Linux x64 and Win64 using the PGSO
lists in build/pgo_data/.

Environment overrides:
  WINDOWS_CARGO=/path/to/cargo.exe
  WINDOWS_RUSTC=/path/to/rustc.exe
  WINDOWS_BUILD_DIR=/path/to/windows/build/dir
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
    echo "[2/2] Building Win64 compiler"
    if [[ ! -x "$WINDOWS_CARGO" || ! -x "$WINDOWS_RUSTC" ]]; then
        echo "missing Windows cargo/rustc at $WINDOWS_CARGO and $WINDOWS_RUSTC" >&2
        exit 1
    fi
    mkdir -p "$WINDOWS_BUILD_DIR"
    RUSTC="$WINDOWS_RUSTC" CARGO="$WINDOWS_CARGO" \
    RUSTFLAGS_NOT_BOOTSTRAP="-Z hot-cold-split -Z cgu-opt-levels=$PGO_DIR/cgu_opt_levels.txt -Z fn-opt-levels=$PGO_DIR/fn_opt_levels.txt" \
        python3 "$ROOT/x.py" build --stage 2 --host "$WINDOWS_HOST" compiler/rustc library/std --build-dir "$WINDOWS_BUILD_DIR"
    mkdir -p "$WINDOWS_OUT"
    cp "$WINDOWS_BUILD_DIR/$WINDOWS_HOST/stage2/bin/rustc.exe" "$WINDOWS_OUT/rustc.exe"
    cp "$WINDOWS_BUILD_DIR/$WINDOWS_HOST/stage2-rustc/$WINDOWS_HOST/release/librustc_driver.dll" "$WINDOWS_OUT/" 2>/dev/null || true
    cat > "$WINDOWS_OUT/BUILD.txt" <<EOF
Built: $(date -u '+%Y-%m-%d %H:%M UTC')
Host: $WINDOWS_HOST
Windows cargo: $WINDOWS_CARGO
Windows rustc: $WINDOWS_RUSTC
Windows build dir: $WINDOWS_BUILD_DIR
PGSO lists: $PGO_DIR/fn_opt_levels.txt, $PGO_DIR/cgu_opt_levels.txt
EOF
fi
