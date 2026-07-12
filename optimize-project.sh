#!/usr/bin/env bash
set -euo pipefail

TOOLCHAIN_NAME="pgso-almalinux8"
TC_DIR="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$TOOLCHAIN_NAME"
RELEASE_URL="https://github.com/gmatht/rust/releases/download/v1.96.1-pgso-binary"
TARBALL="release-almalinux8.tar.gz"
STOCK_TC="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/1.96.1-x86_64-unknown-linux-gnu"
NIGHTLY_TC="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/nightly-x86_64-unknown-linux-gnu"

GEN_SCRIPT_URL="https://raw.githubusercontent.com/gmatht/rust/v1.96-pgso/src/tools/generate_opt_levels.py"

usage() {
    cat <<'EOF'
Usage: optimize-project.sh --train-cmd 'CMD' [--workdir PATH] [--output-dir PATH]
       optimize-project.sh --profdata FILE.profdata [--workdir PATH] [--output-dir PATH]

Options:
  --train-cmd CMD    Training command to generate PGO profiles (required unless --profdata)
  --profdata FILE    Use an existing merged .profdata file (skip training)
  --profile FILE     Same as --profdata
  --workdir PATH     Project root directory (default: .)
  --output-dir PATH  Output directory (default: <workdir>/target/pgo/)
  -o PATH            Same as --output-dir
EOF
}

TRAIN_CMD=""
PROFDATA=""
WORKDIR="."
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --train-cmd)
            TRAIN_CMD="$2"
            shift 2
            ;;
        --profdata|--profile)
            PROFDATA="$2"
            shift 2
            ;;
        --output-dir|-o)
            OUT_DIR="$2"
            shift 2
            ;;
        --workdir)
            WORKDIR="$2"
            shift 2
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
done

if [[ -z "$TRAIN_CMD" && -z "$PROFDATA" ]]; then
    echo "error: need --train-cmd or --profdata" >&2
    usage >&2
    exit 1
fi

# Resolve paths to absolute
WORKDIR="$(readlink -f "$WORKDIR" 2>/dev/null || echo "$WORKDIR")"
if [[ -n "$PROFDATA" ]]; then
    PROFDATA_DIR="$(readlink -f "$(dirname "$PROFDATA")" 2>/dev/null)" || PROFDATA_DIR=""
    if [[ -n "$PROFDATA_DIR" ]]; then
        PROFDATA="$PROFDATA_DIR/$(basename "$PROFDATA")"
    fi
fi
if [[ -n "$OUT_DIR" ]]; then
    case "$OUT_DIR" in
        /*) ;;  # already absolute
        *) OUT_DIR="$WORKDIR/$OUT_DIR" ;;
    esac
fi

ensure_stock() {
    if [[ ! -x "$STOCK_TC/bin/rustc" ]]; then
        echo "Stock 1.96.1 not found at $STOCK_TC" >&2
        echo "Install: rustup toolchain install 1.96.1-x86_64-unknown-linux-gnu" >&2
        exit 1
    fi
}

ensure_toolchain() {
    if [[ -x "$TC_DIR/bin/rustc" ]]; then
        return 0
    fi
    ensure_stock

    rm -rf "$TC_DIR"
    mkdir -p "$TC_DIR/bin" "$TC_DIR/lib/rustlib"

    echo "Downloading $TOOLCHAIN_NAME toolchain..." >&2
    EXTRACT="/tmp/pgso-extract-$$"
    mkdir -p "$EXTRACT"
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

    # Copy compiler binary
    if [[ -f "$EXTRACT/bin/rustc" ]]; then
        cp "$EXTRACT/bin/rustc" "$TC_DIR/bin/rustc"
    elif [[ -f "$EXTRACT/rustc" ]]; then
        # Handle flat tarball structure
        cp "$EXTRACT/rustc" "$TC_DIR/bin/rustc"
    else
        echo "error: rustc not found in tarball" >&2; exit 1
    fi

    # Copy driver library (hashed name)
    for f in "$EXTRACT/lib/"*; do
        bn=$(basename "$f")
        [[ "$bn" == librustc_driver-* ]] && cp "$f" "$TC_DIR/lib/$bn" && ln -sf "$bn" "$TC_DIR/lib/librustc_driver.so"
    done
    # Also handle flat tarball where driver is at root
    if [[ -f "$EXTRACT/librustc_driver.so" ]] && ! ls "$TC_DIR/lib"/librustc_driver-* &>/dev/null; then
        DRV_HASH=$(readelf -d "$TC_DIR/bin/rustc" | awk '/NEEDED.*librustc_driver/{print $5}' | tr -d '[]')
        if [[ -n "$DRV_HASH" ]]; then
            cp "$EXTRACT/librustc_driver.so" "$TC_DIR/lib/$DRV_HASH"
            ln -sf "$DRV_HASH" "$TC_DIR/lib/librustc_driver.so"
        fi
    fi

    # Copy share/ (generate_opt_levels.py) from tarball
    if [[ -d "$EXTRACT/share" ]]; then
        cp -r "$EXTRACT/share" "$TC_DIR/"
    fi
    # Override with latest from GitHub origin/v1.96-pgso
    mkdir -p "$TC_DIR/share"
    if command -v curl &>/dev/null; then
        curl -sL "$GEN_SCRIPT_URL" -o "$TC_DIR/share/generate_opt_levels.py" 2>/dev/null || true
    elif command -v wget &>/dev/null; then
        wget -q "$GEN_SCRIPT_URL" -O "$TC_DIR/share/generate_opt_levels.py" 2>/dev/null || true
    fi

    # Copy host stdlib (matching build, needed for build scripts)
    if [[ -d "$EXTRACT/lib/rustlib/x86_64-unknown-linux-gnu" ]]; then
        cp -r "$EXTRACT/lib/rustlib/x86_64-unknown-linux-gnu" "$TC_DIR/lib/rustlib/"
    fi
    rm -rf "$EXTRACT"

    # rust-src for -Z build-std
    rustup component add rust-src --toolchain "$(basename "$STOCK_TC")" 2>/dev/null || true
    ln -sfn "$STOCK_TC/lib/rustlib/src" "$TC_DIR/lib/rustlib/src"

    # Symlink cargo (nightly preferred for -Z build-std)
    if [[ -x "$NIGHTLY_TC/bin/cargo" ]]; then
        ln -sf "$NIGHTLY_TC/bin/cargo" "$TC_DIR/bin/cargo"
    else
        ln -sf "$STOCK_TC/bin/cargo" "$TC_DIR/bin/cargo"
    fi

    # Symlink LLVM from stock (identical version) - needed in both lib/ and rustlib lib/
    ln -sf "$STOCK_TC/lib/libLLVM-22-rust-1.96.1-stable.so" "$TC_DIR/lib/"
    ln -sf "$STOCK_TC/lib/libLLVM.so.22.1-rust-1.96.1-stable" "$TC_DIR/lib/"
    ln -sf "$STOCK_TC/lib/libLLVM.so.22.1-rust-1.96.1-stable" "$TC_DIR/lib/rustlib/x86_64-unknown-linux-gnu/lib/"
    ln -sf "$STOCK_TC/lib/libLLVM-22-rust-1.96.1-stable.so" "$TC_DIR/lib/rustlib/x86_64-unknown-linux-gnu/lib/"

    # Ensure rustlib lib dir exists for LLVM symlinks
    mkdir -p "$TC_DIR/lib/rustlib/x86_64-unknown-linux-gnu/lib"

    # Symlink self-contained linker (our rustc was built with lld)
    mkdir -p "$TC_DIR/lib/rustlib/x86_64-unknown-linux-gnu/bin"
    ln -sf "$STOCK_TC/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld" "$TC_DIR/lib/rustlib/x86_64-unknown-linux-gnu/bin/"
    rm -rf "$TC_DIR/lib/rustlib/x86_64-unknown-linux-gnu/bin/gcc-ld"
    ln -sfn "$STOCK_TC/lib/rustlib/x86_64-unknown-linux-gnu/bin/gcc-ld" "$TC_DIR/lib/rustlib/x86_64-unknown-linux-gnu/bin/"

    echo "Installed. Use: cargo +$TOOLCHAIN_NAME -Z build-std build --release" >&2
}

# Default output directory
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$WORKDIR/target/pgo"
fi

ensure_toolchain

abs_out="$(cd "$WORKDIR" && mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
PGO_DIR="$abs_out/pgo"
TRAIN_DIR="$abs_out/train"
mkdir -p "$PGO_DIR" "$TRAIN_DIR"

# Find llvm-profdata
llvm_profdata=$(find "$TC_DIR" -name llvm-profdata -type f 2>/dev/null | head -1)
if [[ -z "$llvm_profdata" ]]; then
    llvm_profdata="$(command -v llvm-profdata || true)"
    if [[ -z "$llvm_profdata" || ! -x "$llvm_profdata" ]]; then
        echo "llvm-profdata not found" >&2
        exit 1
    fi
fi

if [[ -n "$TRAIN_CMD" ]]; then
    # ---- Training mode: instrumented build -> run -> merge ----
    printf '%s\n' "$TRAIN_CMD" > "$TRAIN_DIR/train.cmd"
    echo "[1/4] Running training command"
    pushd "$WORKDIR" >/dev/null
    RUSTC="$TC_DIR/bin/rustc" CARGO="cargo +$TOOLCHAIN_NAME" \
    RUSTFLAGS="${RUSTFLAGS:-} -Cprofile-generate=$PGO_DIR" \
        bash -lc "$TRAIN_CMD" \
        >"$TRAIN_DIR/train.stdout" 2>"$TRAIN_DIR/train.stderr"
    popd >/dev/null
    echo "[2/4] Merging profiles"
    profiles=("$PGO_DIR"/*.profraw)
    if [[ ! -e "${profiles[0]}" ]]; then
        echo "no .profraw files found in $PGO_DIR" >&2
        exit 1
    fi
    LD_LIBRARY_PATH="$TC_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$llvm_profdata" merge -o "$abs_out/merged.profdata" "${profiles[@]}"
    PROFDATA="$abs_out/merged.profdata"
fi

# ---- Generate opt-level lists from profile data ----
echo "[3/4] Generating opt-level lists"
LD_LIBRARY_PATH="$TC_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    python3 "$TC_DIR/share/generate_opt_levels.py" \
    --profdata "$PROFDATA" \
    --llvm-profdata "$llvm_profdata" \
    --fn-opt-levels "$abs_out/fn_opt_levels.txt" \
    --cgu-opt-levels "$abs_out/cgu_opt_levels.txt"

# ---- Rebuild with PGO + PGSO ----
echo "[4/4] Rebuilding with PGO + PGSO"
pushd "$WORKDIR" >/dev/null
RUSTC="$TC_DIR/bin/rustc" \
RUSTFLAGS="-Cprofile-use=$PROFDATA -Z hot-cold-split -Z cgu-opt-levels=$abs_out/cgu_opt_levels.txt -Z fn-opt-levels=$abs_out/fn_opt_levels.txt" \
    cargo "+$TOOLCHAIN_NAME" build --release \
    >"$TRAIN_DIR/rebuild.stdout" 2>"$TRAIN_DIR/rebuild.stderr"
popd >/dev/null
echo "saved to $abs_out"
