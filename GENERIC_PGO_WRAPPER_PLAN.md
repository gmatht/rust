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
4. Extract counts and generate opt-level lists
5. Rebuild optimized compiler

## Open issue
- The repo still needs a stable extractor from LLVM PGO data to the `function_counts.txt` format expected by `generate_opt_levels.py`.
