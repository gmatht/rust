#!/usr/bin/env python3
"""Generate CGU and function opt-level files from PGO block counts."""
from collections import defaultdict

counts_path = "/tmp/function_counts.txt"
max_count = 0
counts = {}

with open(counts_path) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) == 2:
            name, count_str = parts
            count = int(count_str)
            counts[name] = count
            max_count = max(max_count, count)

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
    "rustc_abi",
    "rustc_apfloat",
    "rustc_arena",
    "rustc_ast",
    "rustc_ast_lowering",
    "rustc_ast_passes",
    "rustc_ast_pretty",
    "rustc_attr_parsing",
    "rustc_borrowck",
    "rustc_builtin_macros",
    "rustc_codegen_llvm",
    "rustc_codegen_ssa",
    "rustc_const_eval",
    "rustc_data_structures",
    "rustc_driver_impl",
    "rustc_error_codes",
    "rustc_error_messages",
    "rustc_errors",
    "rustc_expand",
    "rustc_feature",
    "rustc_fs_util",
    "rustc_graphviz",
    "rustc_hash",
    "rustc_hashes",
    "rustc_hir",
    "rustc_hir_analysis",
    "rustc_hir_pretty",
    "rustc_hir_typeck",
    "rustc_incremental",
    "rustc_index",
    "rustc_infer",
    "rustc_interface",
    "rustc_lint",
    "rustc_lint_defs",
    "rustc_lexer",
    "rustc_llvm",
    "rustc_log",
    "rustc_metadata",
    "rustc_middle",
    "rustc_mir_build",
    "rustc_mir_dataflow",
    "rustc_mir_transform",
    "rustc_monomorphize",
    "rustc_next_trait_solver",
    "rustc_parse",
    "rustc_parse_format",
    "rustc_passes",
    "rustc_pattern_analysis",
    "rustc_privacy",
    "rustc_proc_macro",
    "rustc_query_impl",
    "rustc_resolve",
    "rustc_sanitizers",
    "rustc_serialize",
    "rustc_session",
    "rustc_span",
    "rustc_symbol_mangling",
    "rustc_target",
    "rustc_thread_pool",
    "rustc_trait_selection",
    "rustc_traits",
    "rustc_transmute",
    "rustc_ty_utils",
    "rustc_type_ir",
    "core",
    "alloc",
    "std",
    "hashbrown",
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

print(
    f"Wrote /tmp/fn_opt_levels.txt ({sum(1 for c in counts.values() if c > tepid_thr)} classified)"
)
print(
    f"Wrote /tmp/cgu_opt_levels.txt ({sum(1 for _, n in crate_counts.values() if n > 0)} crates)"
)
