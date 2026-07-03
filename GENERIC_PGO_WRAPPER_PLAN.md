# Generic PGO Wrapper Plan

Goal: make `optimize-rustc.sh` work on arbitrary Cargo or Rust projects by accepting a user-supplied training command and project root.

## Interface
- `--train-cmd <cmd>`: command string to profile (required)
- `--workdir <path>`: directory to run the workload in (default: `.`)
- `--profraw-dir <path>`: where profile files are emitted
- `--profdata-out <path>`: merged profile path
- `--counts-out <path>`: extracted function-count input for `generate_opt_levels.py`

## Workflow
1. Build instrumented compiler
2. Run the supplied command under the instrumented compiler from the project root (`Cargo.toml` lives there)
3. Merge `.profraw` files with `llvm-profdata`
4. Emit `function_counts.txt` with `-Z function-block-counts`
5. Generate opt-level lists from that counts file
6. Rebuild optimized compiler
