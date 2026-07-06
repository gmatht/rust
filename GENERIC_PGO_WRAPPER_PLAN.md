# Generic PGO Wrapper Plan

Goal: make `optimize-rustc.sh` work on arbitrary Cargo or Rust projects by accepting a user-supplied training command and project root.

## Interface
- `--train-cmd <cmd>`: command string to profile (required unless `--profdata`)
- `--profdata <file>`: existing merged `.profdata` to skip training
- `--profile <file>`: alias for `--profdata`
- `--workdir <path>`: directory to run the workload in (default: `.`)
- `--output-dir <path>` / `-o`: where to write output (default: `<workdir>/target/pgo/`)
- `--profraw-dir <path>`: where profile files are emitted (now under `--output-dir/pgo/`)

## Workflow
1. (with `--train-cmd`) Build instrumented compiler
2. (with `--train-cmd`) Run the supplied command under the instrumented compiler from the project root
3. (with `--train-cmd`) Merge `.profraw` files with `llvm-profdata`
4. Generate opt-level lists from the profile via `generate_opt_levels.py`
5. Rebuild optimized compiler
