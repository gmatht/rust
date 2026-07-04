#!/usr/bin/env bash
set -euo pipefail

TOOLCHAIN_NAME="pgso-almalinux8"
TC_LINK="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$TOOLCHAIN_NAME"
TC_DIR="/tmp/pgso-$TOOLCHAIN_NAME"
RELEASE_URL="https://github.com/gmatht/rust/releases/download/v1.96.1-pgso"
TARBALL="release-almalinux8.tar.gz"
STOCK_TC="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/1.96.1-x86_64-unknown-linux-gnu"
NIGHTLY_TC="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/nightly-x86_64-unknown-linux-gnu"

GEN_SCRIPT="$TC_DIR/share/generate_opt_levels.py"

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

    # Copy share/ (generate_opt_levels.py)
    if [[ -d "$EXTRACT/share" ]]; then
        cp -r "$EXTRACT/share" "$TC_DIR/"
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

    # Register with rustup (TC_DIR is outside ~/.rustup/toolchains/, no circular symlink)
    rm -f "$TC_LINK"
    rustup toolchain link "$TOOLCHAIN_NAME" "$TC_DIR" 2>/dev/null || true

    echo "Installed. Use: cargo +$TOOLCHAIN_NAME -Z build-std build --release" >&2
}

# --- Profile mode: --train-cmd ---
if [[ $# -ge 1 && "$1" == "--train-cmd" ]]; then
    ensure_toolchain
    shift
    TRAIN_CMD="$1"
    shift || true
    WORKDIR="${1:-.}"
    shift 2>/dev/null || true
    OUT_DIR="$WORKDIR/saved/optimized_project"
    PGO_DIR="$OUT_DIR/pgo"
    TRAIN_DIR="$OUT_DIR/train"
    mkdir -p "$PGO_DIR" "$TRAIN_DIR"
    printf '%s\n' "$TRAIN_CMD" > "$TRAIN_DIR/train.cmd"
    echo "[1/3] Running training command"
    pushd "$WORKDIR" >/dev/null
    RUSTC="$TC_DIR/bin/rustc" CARGO="cargo +$TOOLCHAIN_NAME" \
    RUSTFLAGS="${RUSTFLAGS:-} -Cprofile-generate=$PGO_DIR" \
        bash -lc "$TRAIN_CMD" \
        >"$TRAIN_DIR/train.stdout" 2>"$TRAIN_DIR/train.stderr"
    popd >/dev/null
    echo "[2/3] Merging profiles"
    # Prefer the toolchain's own llvm-profdata (matches our LLVM version)
    llvm_profdata=$(find "$TC_DIR" -name llvm-profdata -type f 2>/dev/null | head -1)
    if [[ -z "$llvm_profdata" ]]; then
        llvm_profdata="$(command -v llvm-profdata || true)"
        [[ -x "$llvm_profdata" ]] || { echo "llvm-profdata not found" >&2; exit 1; }
    fi
    profiles=("$PGO_DIR"/*.profraw)
    LD_LIBRARY_PATH="$TC_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$llvm_profdata" merge -o "$OUT_DIR/merged.profdata" "${profiles[@]}"
    echo "[3/4] Generating opt-level lists"
    python3 "$GEN_SCRIPT" --profdata "$OUT_DIR/merged.profdata" --llvm-profdata "$llvm_profdata"
    cp /tmp/cgu_opt_levels.txt "$OUT_DIR/cgu_opt_levels.txt" 2>/dev/null || true
    cp /tmp/fn_opt_levels.txt "$OUT_DIR/fn_opt_levels.txt" 2>/dev/null || true
    echo "[4/4] Rebuilding with PGO + PGSO"
    pushd "$WORKDIR" >/dev/null
    RUSTC="$TC_DIR/bin/rustc" \
    RUSTFLAGS="-Cprofile-use=$OUT_DIR/merged.profdata -Z cgu-opt-levels=$OUT_DIR/cgu_opt_levels.txt -Z fn-opt-levels=$OUT_DIR/fn_opt_levels.txt" \
        cargo "+$TOOLCHAIN_NAME" build --release \
        >"$TRAIN_DIR/rebuild.stdout" 2>"$TRAIN_DIR/rebuild.stderr"
    popd >/dev/null
    echo "saved to $OUT_DIR"
    exit 0
fi

# --- Default mode: cargo passthrough ---
ensure_toolchain
if [[ $# -eq 0 ]]; then
    echo "$TC_DIR"
    exit 0
fi
exec cargo "+$TOOLCHAIN_NAME" "$@"
