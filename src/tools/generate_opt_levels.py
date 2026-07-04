#!/usr/bin/env python3
"""Generate CGU and function opt-level files from PGO profile data.

Usage: generate_opt_levels.py --profdata <file.profdata>

Extracts function block counts from a merged LLVM profile, classifies
functions as hot/warm/tepid/cold, and writes CGU and function opt-level
files consumed by -Z cgu-opt-levels and -Z fn-opt-levels.
"""
import argparse
import subprocess
import sys
import re
from collections import defaultdict

def extract_counts(profdata_path):
    """Run llvm-profdata show and parse function names + block counts."""
    llvm_profdata = find_llvm_profdata()
    result = subprocess.run(
        [llvm_profdata, "show", "--all-functions", "--counts", profdata_path],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"error: llvm-profdata failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    counts = {}
    current_func = None
    for line in result.stdout.split("\n"):
        # Function names: exactly 2-space indent, no spaces in the name itself
        if line.startswith("  ") and not line.startswith("    ") and line.rstrip().endswith(":") and not line.strip().startswith("Counters"):
            current_func = line.strip().rstrip(":")
        elif "Block counts:" in line and current_func:
            match = re.findall(r"\d+", line)
            total = sum(int(x) for x in match)
            if total > 0:
                # Strip CGU prefix (e.g. "corro.219e2ace-cgu.0;") leaving the mangled symbol
                mangled = current_func.split(";", 1)[-1] if ";" in current_func else current_func
                demangled = demangle(mangled)
                if demangled and demangled not in counts:
                    counts[demangled] = total
            current_func = None
    return counts

PROFDATA_CANDIDATES = [
    "llvm-profdata",
    "/root/.rustup/toolchains/1.96.1-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata",
    "/root/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata",
]

def find_llvm_profdata():
    """Find llvm-profdata in rustup toolchains or system PATH."""
    for c in PROFDATA_CANDIDATES:
        try:
            subprocess.run([c, "--version"], capture_output=True)
            return c
        except FileNotFoundError:
            continue
    print("error: llvm-profdata not found", file=sys.stderr)
    sys.exit(1)

def demangle(name):
    """Demangle a Rust function name using rustfilt."""
    try:
        result = subprocess.run(["rustfilt"], input=name, capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else name
    except FileNotFoundError:
        return name

def main():
    parser = argparse.ArgumentParser(description="Generate PGSO opt-level files from PGO profile")
    parser.add_argument("--profdata", required=True, help="Path to merged .profdata file")
    parser.add_argument("--llvm-profdata", help="Path to llvm-profdata binary")
    args = parser.parse_args()

    if args.llvm_profdata:
        PROFDATA_CANDIDATES.insert(0, args.llvm_profdata)

    counts = extract_counts(args.profdata)
    if not counts:
        print("error: no function counts extracted from profile", file=sys.stderr)
        sys.exit(1)

    max_count = max(counts.values())
    hot_thr = max(max_count // 100, 1)
    warm_thr = max(max_count * 2 // 1000, 1)
    tepid_thr = max(max_count // 2000, 1)

    # --- Function opt-levels ---
    with open("/tmp/fn_opt_levels.txt", "w") as f:
        for name, count in sorted(counts.items(), key=lambda x: -x[1]):
            if count > hot_thr:
                f.write(f"{name} O3\n")
            elif count > warm_thr:
                f.write(f"{name} O2\n")
            elif count > tepid_thr:
                f.write(f"{name} Os\n")

    # --- CGU opt-levels ---
    known_crates = [
        "rustc_abi", "rustc_apfloat", "rustc_arena", "rustc_ast", "rustc_ast_lowering",
        "rustc_ast_passes", "rustc_ast_pretty", "rustc_attr_parsing", "rustc_borrowck",
        "rustc_builtin_macros", "rustc_codegen_llvm", "rustc_codegen_ssa", "rustc_const_eval",
        "rustc_data_structures", "rustc_driver_impl", "rustc_error_codes", "rustc_error_messages",
        "rustc_errors", "rustc_expand", "rustc_feature", "rustc_fs_util", "rustc_graphviz",
        "rustc_hash", "rustc_hashes", "rustc_hir", "rustc_hir_analysis", "rustc_hir_pretty",
        "rustc_hir_typeck", "rustc_incremental", "rustc_index", "rustc_infer", "rustc_interface",
        "rustc_lint", "rustc_lint_defs", "rustc_lexer", "rustc_llvm", "rustc_log",
        "rustc_metadata", "rustc_middle", "rustc_mir_build", "rustc_mir_dataflow",
        "rustc_mir_transform", "rustc_monomorphize", "rustc_next_trait_solver", "rustc_parse",
        "rustc_parse_format", "rustc_passes", "rustc_pattern_analysis", "rustc_privacy",
        "rustc_proc_macro", "rustc_query_impl", "rustc_resolve", "rustc_sanitizers",
        "rustc_serialize", "rustc_session", "rustc_span", "rustc_symbol_mangling",
        "rustc_target", "rustc_thread_pool", "rustc_trait_selection", "rustc_traits",
        "rustc_transmute", "rustc_ty_utils", "rustc_type_ir",
        "core", "alloc", "std", "hashbrown",
    ]

    crate_counts = defaultdict(lambda: [0, 0])
    for name, count in counts.items():
        for crate in known_crates:
            if name.startswith(crate + "::") or name == crate:
                crate_counts[crate][0] += count
                crate_counts[crate][1] += 1
                break

    with open("/tmp/cgu_opt_levels.txt", "w") as f:
        f.write("# CGU opt levels (prefix match against crate name)\n")
        for crate in known_crates:
            total, n = crate_counts.get(crate, (0, 0))
            if n == 0:
                continue
            avg = total / n
            if avg > hot_thr:
                level = "O3"
            elif avg > warm_thr:
                level = "O2"
            elif avg > tepid_thr:
                level = "Os"
            else:
                level = "Oz"
            f.write(f"{crate} {level}\n")

    classified = sum(1 for c in counts.values() if c > tepid_thr)
    crates = sum(1 for _, n in crate_counts.values() if n > 0)
    print(f"Extracted {len(counts)} functions from {args.profdata}")
    print(f"Wrote /tmp/fn_opt_levels.txt ({classified} classified)")
    print(f"Wrote /tmp/cgu_opt_levels.txt ({crates} crates)")

if __name__ == "__main__":
    main()
