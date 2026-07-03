#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT/saved/optimized_project"
PGO_DIR="$OUT_DIR/pgo"
TRAIN_DIR="$OUT_DIR/train"
COUNTS_FILE="$PGO_DIR/function_counts.txt"

usage() {
    cat <<'EOF'
Usage: optimize-project.sh --train-cmd '...' [--workdir PATH] [-- extra args...]

Profiles a Cargo/Rust project by running the supplied training command with
Rust PGO enabled, then merges the resulting profiles and writes function block
counts in the same format as `generate_opt_levels.py` expects.

`--train-cmd` is mandatory.
`--workdir` defaults to `.` and should point at the project root.
Any arguments after `--` are appended to the training command.
EOF
}

TRAIN_CMD=""
WORKDIR="."
TRAIN_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --train-cmd)
            TRAIN_CMD="$2"
            shift 2
            ;;
        --workdir)
            WORKDIR="$2"
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

if [[ -z "$TRAIN_CMD" ]]; then
    echo "missing --train-cmd" >&2
    usage >&2
    exit 1
fi

mkdir -p "$PGO_DIR" "$TRAIN_DIR"

TRAIN_CMD_LINE="$TRAIN_CMD"
if [[ ${#TRAIN_ARGS[@]} -gt 0 ]]; then
    for arg in "${TRAIN_ARGS[@]}"; do
        TRAIN_CMD_LINE+=" $(printf '%q' "$arg")"
    done
fi
printf '%s\n' "$TRAIN_CMD_LINE" > "$TRAIN_DIR/train.cmd"

echo "[1/2] Running training command"
pushd "$WORKDIR" >/dev/null
RUSTFLAGS="${RUSTFLAGS:-} -Cprofile-generate=$PGO_DIR -Zfunction-block-counts=$COUNTS_FILE" \
    bash -lc "$TRAIN_CMD_LINE" \
    >"$TRAIN_DIR/train.stdout" 2>"$TRAIN_DIR/train.stderr"
popd >/dev/null

echo "[2/2] Merging profiles"
llvm_profdata="$(command -v llvm-profdata || true)"
if [[ -z "$llvm_profdata" ]]; then
    echo "llvm-profdata not found in PATH" >&2
    exit 1
fi

profiles=("$PGO_DIR"/*.profraw)
if [[ ! -e "${profiles[0]}" ]]; then
    echo "no .profraw files found in $PGO_DIR" >&2
    exit 1
fi

"$llvm_profdata" merge -o "$OUT_DIR/merged.profdata" "${profiles[@]}"

if [[ ! -s "$COUNTS_FILE" ]]; then
    echo "function counts were not written to $COUNTS_FILE" >&2
    exit 1
fi

cat > "$OUT_DIR/README.txt" <<EOF
Generic PGO capture completed.
Training command: $TRAIN_CMD_LINE
Merged profile: $OUT_DIR/merged.profdata
Function counts: $COUNTS_FILE
EOF

echo "saved to $OUT_DIR"
