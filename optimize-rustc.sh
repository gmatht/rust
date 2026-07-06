#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build/x86_64-unknown-linux-gnu"
HOST_TRIPLE="x86_64-unknown-linux-gnu"
PGO_DIR="$BUILD_DIR/pgo_data"
TRAIN_DIR="$BUILD_DIR/pgo_train"
OUT_DIR="$ROOT/saved/optimized_rustc"
TRAIN_CMD_FILE="$TRAIN_DIR/train.cmd"

usage() {
    cat <<'EOF'
Usage: optimize-rustc.sh --train-cmd '...' [--workdir PATH] [--output-dir PATH] [-- extra args...]
       optimize-rustc.sh --profdata FILE.profdata [--output-dir PATH]

This script:
  1. (with --train-cmd) builds an instrumented stage2 compiler
  2. (with --train-cmd) runs the supplied training command in the project root
  3. (with --train-cmd) merges the resulting PGO data
  4. regenerates fn/cgu opt-level lists
  5. rebuilds an optimized stage2 compiler
  6. saves the result under --output-dir (default: saved/optimized_rustc)

With --profdata, steps 1-3 are skipped and the given profile is used directly.
At least one of --train-cmd or --profdata must be provided.
EOF
}

TRAIN_CMD=""
PROFDATA=""
WORKDIR="."
OUT_DIR=""
TRAIN_ARGS=()

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
        --workdir)
            WORKDIR="$2"
            shift 2
            ;;
        --output-dir|-o)
            OUT_DIR="$2"
            shift 2
            ;;
        --)
            shift
            TRAIN_ARGS+=("$@")
            break
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
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$ROOT/saved/optimized_rustc"
else
    case "$OUT_DIR" in
        /*) ;;  # already absolute
        *) OUT_DIR="$WORKDIR/$OUT_DIR" ;;
    esac
fi

mkdir -p "$PGO_DIR" "$TRAIN_DIR" "$OUT_DIR"

if [[ -n "$TRAIN_CMD" ]]; then
    TRAIN_CMD_LINE="$TRAIN_CMD"
    if [[ ${#TRAIN_ARGS[@]} -gt 0 ]]; then
        for arg in "${TRAIN_ARGS[@]}"; do
            TRAIN_CMD_LINE+=" $(printf '%q' "$arg")"
        done
    fi
    printf '%s\n' "$TRAIN_CMD_LINE" > "$TRAIN_CMD_FILE"

    echo "[1/5] Building instrumented stage2 compiler"
    python3 "$ROOT/x.py" build --stage 2 library/std compiler/rustc \
        --rust-profile-generate="$PGO_DIR/rustc-profraw"

    echo "[2/5] Running training command"
    pushd "$WORKDIR" >/dev/null
    bash -lc "$TRAIN_CMD_LINE" \
        >"$TRAIN_DIR/train.stdout" 2>"$TRAIN_DIR/train.stderr"
    popd >/dev/null

    echo "[3/5] Merging profiles"
    llvm_profdata="$(command -v llvm-profdata || true)"
    if [[ -z "$llvm_profdata" ]]; then
        llvm_profdata="$BUILD_DIR/ci-llvm/bin/llvm-profdata"
    fi
    rm -f "$PGO_DIR/merged.profdata"
    profiles=("$PGO_DIR"/*.profraw)
    if [[ ! -e "${profiles[0]}" ]]; then
        echo "no .profraw files found in $PGO_DIR" >&2
        exit 1
    fi
    "$llvm_profdata" merge -o "$PGO_DIR/merged.profdata" "${profiles[@]}"
    PROFDATA="$PGO_DIR/merged.profdata"
else
    llvm_profdata="$(command -v llvm-profdata || true)"
    if [[ -z "$llvm_profdata" ]]; then
        llvm_profdata="$BUILD_DIR/ci-llvm/bin/llvm-profdata"
    fi
fi

echo "[4/5] Generating opt-level lists"
python3 "$ROOT/src/tools/generate_opt_levels.py" \
    --profdata "$PROFDATA" \
    --llvm-profdata "$llvm_profdata" \
    --fn-opt-levels "$PGO_DIR/fn_opt_levels.txt" \
    --cgu-opt-levels "$PGO_DIR/cgu_opt_levels.txt"

echo "[5/5] Building optimized stage2 compiler"
RUSTFLAGS_NOT_BOOTSTRAP="-Z hot-cold-split -Z cgu-opt-levels=$PGO_DIR/cgu_opt_levels.txt -Z fn-opt-levels=$PGO_DIR/fn_opt_levels.txt" \
    python3 "$ROOT/x.py" build --stage 2 compiler/rustc library/std \
    --rust-profile-use="$PROFDATA"

cp "$BUILD_DIR/stage2/bin/rustc" "$OUT_DIR/rustc"
cp "$BUILD_DIR/stage2-rustc/$HOST_TRIPLE/release/librustc_driver.so" "$OUT_DIR/"

{
    echo "Built: $(date -u '+%Y-%m-%d %H:%M UTC')"
    if [[ -n "$TRAIN_CMD" ]]; then
        echo "Training command: $TRAIN_CMD"
    fi
    echo "Profiles: $PROFDATA"
    echo "Lists: $PGO_DIR/fn_opt_levels.txt, $PGO_DIR/cgu_opt_levels.txt"
} > "$OUT_DIR/BUILD.txt"

echo "saved to $OUT_DIR"
