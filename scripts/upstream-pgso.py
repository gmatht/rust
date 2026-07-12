#!/usr/bin/env python3
"""
Unified PGSO + per-crate optimizer (upstream rustc only, no fork).

Combines:
  1. PGO training (instrumented build -> run -> merge)
  2. Per-function minsize/optsize via --forceattrs-csv-path (upstream LLVM)
  3. Per-crate opt-level overrides via CARGO_PROFILE env vars
  4. Optional brute-force loop to refine per-crate configs
  5. Binary hashing for DCE detection / identical-build detection

Works for both rustc itself (via x.py) and standard Cargo projects.

Usage:
  # Build the compiler
  ./scripts/upstream-pgso.py --train-cmd 'cargo build --release && ./target/release/myapp'

  # Optimise a cargo project
  ./scripts/upstream-pgso.py --project /path/to/project \\
    --train-cmd 'cargo build --release && ./target/release/bench'

  # With an existing profile (skip training)
  ./scripts/upstream-pgso.py --project . --profdata merged.profdata --brute
"""
import argparse, os, sys, subprocess, re, shutil, glob, textwrap, json
import hashlib, time
from collections import defaultdict

HOST_TRIPLE = "x86_64-unknown-linux-gnu"
SRC_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def find_llvm_profdata(profdata=None):
    candidates = []
    candidates += glob.glob("/root/.rustup/toolchains/*/lib/rustlib/*/bin/llvm-profdata")
    candidates += glob.glob(os.path.join(SRC_DIR, "build", "*", "ci-llvm", "bin", "llvm-profdata"))
    system = shutil.which("llvm-profdata")
    if system:
        candidates.append(system)
    tested = set()
    for c in candidates:
        if not c or c in tested or not os.access(c, os.X_OK):
            continue
        tested.add(c)
        try:
            if profdata and os.path.isfile(profdata):
                r = subprocess.run([c, "show", "--counts", profdata],
                                   capture_output=True, timeout=30)
                if r.returncode == 0:
                    return c
            else:
                subprocess.run([c, "--version"], capture_output=True, timeout=10)
                return c
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    sys.exit("error: no usable llvm-profdata found")

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def run_capture(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)

# ---------------------------------------------------------------------------
# PGO profile extraction
# ---------------------------------------------------------------------------
FN_ATTR_OPSIZE = "optsize"
FN_ATTR_MINSIZE = "minsize"
OPT_TO_CARGO = {"O3": "3", "O2": "2", "Os": "s", "Oz": "z"}
OPT_TO_ORDER = {"Oz": 0, "Os": 1, "O2": 2, "O3": 3}

def extract_counts(profdata, llvm_pd):
    r = run_capture([llvm_pd, "show", "--all-functions", "--counts", profdata])
    if r.returncode != 0:
        sys.exit(f"llvm-profdata failed: {r.stderr}")
    counts = {}
    current = None
    for line in r.stdout.splitlines():
        if line.startswith("  ") and not line.startswith("    ") and line.rstrip().endswith(":") and "Counters" not in line:
            current = line.strip().rstrip(":")
        elif "Block counts:" in line and current:
            total = sum(int(x) for x in re.findall(r"\d+", line))
            if total > 0:
                mangled = current.split(";", 1)[-1] if ";" in current else current
                if mangled and mangled not in counts:
                    counts[mangled] = total
            current = None
    return counts

def demangle(name):
    try:
        r = subprocess.run(["rustfilt"], input=name, capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else name
    except FileNotFoundError:
        return name

def classify(count, max_count, hot_div, warm_div, tepid_div):
    hot = max(max_count // hot_div, 1) if hot_div else 0
    warm = max(max_count * 2 // warm_div, 1) if warm_div else 0
    tepid = max(max_count // tepid_div, 1) if tepid_div else 0
    if count > hot:
        return "O3", None
    elif count > warm:
        return "O2", None
    elif count > tepid:
        return "Os", FN_ATTR_OPSIZE
    else:
        return "Oz", FN_ATTR_MINSIZE

def crate_from_demangled(demangled, mangled, known_crates):
    for crate in known_crates:
        if demangled.startswith(crate + "::") or demangled == crate or mangled.startswith(crate + "."):
            return crate
    return "_other"

def generate_configs(profdata, llvm_pd, known_crates, fn_attrs_csv, out_list,
                     hot_div, warm_div, tepid_div, o3_everything):
    """Parse profile, classify functions, write configs. Returns (crate_opt, cargo_env)."""
    raw = extract_counts(profdata, llvm_pd)
    if not raw:
        sys.exit("error: no function counts extracted")
    max_count = max(raw.values())
    if o3_everything:
        hot_div = warm_div = tepid_div = 0

    fn_count = {"hot": 0, "warm": 0, "tepid": 0, "optsize": 0, "minsize": 0}
    fn_attrs = {}
    crate_buckets = defaultdict(list)

    for mangled, count in raw.items():
        dem = demangle(mangled)
        opt, attr = classify(count, max_count, hot_div, warm_div, tepid_div)
        if attr:
            fn_attrs[mangled] = attr
            fn_count["minsize" if attr == FN_ATTR_MINSIZE else "optsize"] += 1
        else:
            if count > max(max_count // hot_div, 1):
                fn_count["hot"] += 1
            elif count > max(max_count * 2 // warm_div, 1):
                fn_count["warm"] += 1
            else:
                fn_count["tepid"] += 1
        crate = crate_from_demangled(dem, mangled, known_crates)
        crate_buckets[crate].append((dem, count))

    # per-crate opt-level from average
    crate_opt = {}
    for crate, funcs in crate_buckets.items():
        if not funcs:
            continue
        avg = sum(f[1] for f in funcs) / len(funcs)
        opt, _ = classify(avg, max_count, hot_div, warm_div, tepid_div)
        crate_opt[crate] = (opt, len(funcs))

    # fn_attrs CSV (for --forceattrs-csv-path)
    with open(fn_attrs_csv, "w") as f:
        f.write("# mangled_name,llvm_attr\n")
        for mangled, attr in sorted(fn_attrs.items()):
            f.write(f"{mangled},{attr}\n")

    # crate list (baseline for brute-force)
    with open(out_list, "w") as f:
        f.write("# crate opt-level fn_count\n")
        for crate, (opt, n) in sorted(crate_opt.items()):
            if crate != "_other":
                f.write(f"{crate} {opt}\n")

    # cargo env vars
    cargo_env = {"CARGO_PROFILE_RELEASE_CODEGEN_UNITS": "1"}
    for crate, (opt, _) in crate_opt.items():
        if crate == "_other":
            continue
        upper = crate.upper()
        cargo_env[f"CARGO_PROFILE_RELEASE_PACKAGE_{upper}_OPT_LEVEL"] = OPT_TO_CARGO[opt]

    print(f"  Functions: {len(raw)} total; "
          f"hot={fn_count['hot']} warm={fn_count['warm']} "
          f"optsize={fn_count['optsize']} minsize={fn_count['minsize']}")
    print(f"  Crates: {len(crate_opt)} ({sum(1 for c in crate_opt if c != '_other')} known)")
    print(f"  fn attrs CSV: {fn_attrs_csv} ({len(fn_attrs)} entries)")
    print(f"  crate list:   {out_list} ({len(crate_opt)} entries)")

    return crate_opt, cargo_env

# ---------------------------------------------------------------------------
# Mode: rustc (x.py)
# ---------------------------------------------------------------------------
def discover_rustc_crates():
    return [
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

def xpy_build_rustc(build_dir, profdata, fn_attrs_csv, targets=None, jobs=8, extra_env=None, lto_off=False):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    env["RUSTFLAGS_NOT_BOOTSTRAP"] = f"-C llvm-args=--forceattrs-csv-path={fn_attrs_csv}"
    args = [sys.executable, os.path.join(SRC_DIR, "x.py"),
            "build", "--stage", "2"]
    if profdata and os.path.isfile(profdata):
        args.append(f"--rust-profile-use={profdata}")
    if lto_off:
        args += ["--set", "rust.lto=off"]
    args += ["--build-dir", build_dir, "-j", str(jobs)]
    args += targets or ["library/std", "compiler/rustc"]
    print(f"  + x.py {' '.join(args[2:])}", file=sys.stderr)
    return subprocess.run(args, env=env).returncode == 0

def rustc_so_path(build_dir):
    return os.path.join(build_dir, HOST_TRIPLE,
                        "stage2-rustc", HOST_TRIPLE, "release",
                        "librustc_driver.so")

def rustc_binary(build_dir):
    """Return path to the binary we measure for rustc mode."""
    so = rustc_so_path(build_dir)
    return so if os.path.isfile(so) else None

def force_rebuild_rustc_crate(crate, build_dir):
    for p in [f"compiler/{crate}/src/lib.rs", f"compiler/{crate}/src/main.rs",
              f"library/{crate}/src/lib.rs", f"library/{crate}/src/main.rs"]:
        full = os.path.join(SRC_DIR, p)
        if os.path.isfile(full):
            os.utime(full, None)
            print(f"  Touched {p}")
            return
    pattern = os.path.join(build_dir, HOST_TRIPLE, "stage2-rustc", "**", f"lib{crate}-*.rlib")
    for f in glob.glob(pattern, recursive=True):
        os.remove(f)
        print(f"  Deleted {f}")

# ---------------------------------------------------------------------------
# Mode: cargo project
# ---------------------------------------------------------------------------
def cargo_metadata(project_dir):
    r = run_capture(["cargo", "metadata", "--format-version=1", "--no-deps"],
                    cwd=project_dir)
    if r.returncode != 0:
        sys.exit(f"cargo metadata failed: {r.stderr}")
    return json.loads(r.stdout)

def discover_project_crates(project_dir):
    """Return list of package names from cargo metadata."""
    meta = cargo_metadata(project_dir)
    return [p["name"] for p in meta.get("packages", [])]

def cargo_build_project(project_dir, build_dir, profdata, fn_attrs_csv,
                        args_extra=None, jobs=8, extra_env=None):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    profile_use = ""
    if profdata and os.path.isfile(profdata):
        profile_use = f"-Cprofile-use={profdata} --emit=llvm-ir"
    env["RUSTFLAGS"] = (env.get("RUSTFLAGS", "")
                        + f" -C llvm-args=--forceattrs-csv-path={fn_attrs_csv}"
                        + (f" {profile_use}" if profile_use else ""))
    cmd = ["cargo", "build", "--release", "--target-dir", os.path.join(build_dir, "target")]
    if args_extra:
        cmd += args_extra
    print(f"  + cargo build --release", file=sys.stderr)
    r = subprocess.run(cmd, cwd=project_dir, env=env)
    return r.returncode == 0

def project_binary_path(project_dir, build_dir):
    """Find the release binary from cargo metadata."""
    meta = cargo_metadata(project_dir)
    root_pkg = None
    for p in meta.get("packages", []):
        if p.get("manifest_path"):
            mp = os.path.normpath(p["manifest_path"])
            if mp == os.path.normpath(os.path.join(project_dir, "Cargo.toml")):
                root_pkg = p
                break
    if not root_pkg and meta.get("packages"):
        root_pkg = meta["packages"][0]
    if not root_pkg:
        return None
    name = root_pkg["name"]
    target_dir = os.path.join(build_dir, "target", "release")
    for f in os.listdir(target_dir):
        fp = os.path.join(target_dir, f)
        if os.path.isfile(fp) and os.access(fp, os.X_OK) and f == name:
            return fp
    # also check common binary names
    for f in os.listdir(target_dir):
        fp = os.path.join(target_dir, f)
        if os.path.isfile(fp) and os.access(fp, os.X_OK) and not f.endswith(".d"):
            return fp
    return None

# ---------------------------------------------------------------------------
# brute-force loop (shared)
# ---------------------------------------------------------------------------
def run_brute_loop(crate_list, opt_best, state_file, results_log, build_dir,
                   build_fn, measure_fn, rebuild_crate_fn, profdata, fn_attrs_csv,
                   crate_opt, jobs):
    """Generic brute-force loop.  build_fn(extra_targets) -> bool; measure_fn() -> (size, hash)."""
    lines = []
    with open(crate_list) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                lines.append((parts[0], parts[1]))
    total = len(lines)
    print(f"  Total entries: {total}")

    resume = 0
    if os.path.isfile(state_file):
        with open(state_file) as f:
            resume = int(f.read().strip())
        print(f"  Resuming from entry {resume}")

    if not os.path.isfile(results_log):
        with open(results_log, "w") as f:
            f.write("unix_ts,entry_idx,crate,old_opt,new_opt,build_time_s,size_bytes,sha256\n")

    current_levels = {}
    with open(crate_list) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                current_levels[parts[0]] = parts[1]

    for idx, (crate, current_opt) in enumerate(lines):
        if idx < resume:
            continue
        if current_opt == "O3":
            print(f"[{idx+1}/{total}] {crate} already O3, skipping")
            with open(state_file, "w") as f:
                f.write(f"{idx+1}\n")
            continue

        order = OPT_TO_ORDER[current_opt]
        candidates = [o for o in ("Oz", "Os", "O2", "O3") if OPT_TO_ORDER[o] > order]

        print(f"\n{'='*72}")
        print(f"[{idx+1}/{total}] {crate} (currently {current_opt})")
        print(f"{'='*72}")

        best_size, best_hash, best_opt = 0, "", current_opt

        for new_opt in candidates:
            upper = crate.upper()
            carg_opt = OPT_TO_CARGO[new_opt]
            env_var = f"CARGO_PROFILE_RELEASE_PACKAGE_{upper}_OPT_LEVEL"
            os.environ[env_var] = carg_opt
            print(f"\n--- Trying {crate}: {current_opt} -> {new_opt} ({env_var}={carg_opt}) ---")

            rebuild_crate_fn(crate, build_dir)

            start_ts = time.time()
            ok = build_fn(profdata, fn_attrs_csv,
                          extra_targets=["compiler/rustc"],
                          extra_env={env_var: carg_opt})
            build_time = time.time() - start_ts
            if not ok:
                print("  Build FAILED, skipping")
                continue

            sz, h = measure_fn(build_dir) or (0, "")
            with open(results_log, "a") as f:
                f.write(f"{int(time.time())},{idx+1},{crate},{current_opt},{new_opt},{build_time:.0f},{sz},{h}\n")
            print(f"  size={sz} hash={h} ({build_time:.0f}s)")

            if sz <= 0:
                continue
            if best_size == 0 or sz < best_size:
                best_size, best_hash, best_opt = sz, h, new_opt
                print(f"  NEW BEST: {crate} {new_opt} (size {sz})")
            elif sz == best_size:
                if h != best_hash:
                    if OPT_TO_ORDER[new_opt] > OPT_TO_ORDER[best_opt]:
                        best_size, best_hash, best_opt = sz, h, new_opt
                        print(f"  SAME SIZE, HIGHER OPT: {crate} {new_opt}")
                    else:
                        print(f"  SAME SIZE, keeping {best_opt}")
                else:
                    print("  IDENTICAL binary — LTO DCE'd this crate?")
            else:
                print(f"  WORSE: {sz} > best {best_size}")

        current_levels[crate] = best_opt
        upper = crate.upper()
        os.environ[f"CARGO_PROFILE_RELEASE_PACKAGE_{upper}_OPT_LEVEL"] = OPT_TO_CARGO[best_opt]
        with open(opt_best, "w") as f:
            for c, o in sorted(current_levels.items()):
                f.write(f"{c} {o}\n")
        with open(state_file, "w") as f:
            f.write(f"{idx+1}\n")

    print("\n  Brute-force complete")

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Unified PGSO + per-crate optimizer (upstream rustc only, no fork)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            examples:
              # build the compiler
              %(prog)s --train-cmd '...'
              %(prog)s --profdata merged.profdata --brute

              # build a cargo project
              %(prog)s --project ./myapp --train-cmd './run-bench.sh'
              %(prog)s --project . --profdata merged.profdata --brute
        """))
    ap.add_argument("--project", metavar="DIR",
                    help="Cargo project directory (default: build rustc via x.py)")
    ap.add_argument("--train-cmd", help="Training command (instrumented build + run)")
    ap.add_argument("--profdata", help="Existing merged .profdata (skip training)")
    ap.add_argument("--profile", dest="profdata", help="Same as --profdata")
    ap.add_argument("--brute", action="store_true", help="Run brute-force per-crate search")
    ap.add_argument("-o", "--output-dir", help="Output directory")
    ap.add_argument("-j", "--jobs", type=int, default=8, help="Parallel jobs")
    ap.add_argument("--llvm-profdata", help="Path to llvm-profdata binary")
    ap.add_argument("--hot-div", type=int, default=100, help="Hotness divisor (default 100)")
    ap.add_argument("--warm-div", type=int, default=500, help="Warmth divisor (default 500)")
    ap.add_argument("--tepid-div", type=int, default=2000, help="Tepid divisor (default 2000)")
    ap.add_argument("--o3-everything", action="store_true", help="All functions O3")
    args = ap.parse_args()

    if not args.train_cmd and not args.profdata:
        ap.error("need --train-cmd or --profdata")

    is_rustc = args.project is None
    project_dir = os.path.abspath(args.project) if args.project else None

    build_dir = args.output_dir
    if not build_dir:
        build_dir = os.path.join(SRC_DIR if is_rustc else project_dir, "build", "unified-opt")
    build_dir = os.path.abspath(build_dir)
    pgo_dir = os.path.join(build_dir, "pgo_data")
    os.makedirs(pgo_dir, exist_ok=True)
    os.makedirs(build_dir, exist_ok=True)

    fn_attrs_csv = os.path.join(build_dir, "fn_attrs.csv")
    crate_list = os.path.join(build_dir, "crate_list.txt")
    opt_best = os.path.join(build_dir, "crate_opt_best.txt")
    state_file = os.path.join(build_dir, "brute-state.txt")
    results_log = os.path.join(build_dir, "brute-results.csv")

    profdata = args.profdata
    llvm_pd = args.llvm_profdata or find_llvm_profdata(profdata)

    known_crates = discover_rustc_crates() if is_rustc else discover_project_crates(project_dir)

    print("=" * 73)
    print("  Unified Upstream Optimiser")
    print(f"  Mode:        {'rustc (x.py)' if is_rustc else 'cargo project'}")
    if project_dir:
        print(f"  Project:     {project_dir}")
    print(f"  Build dir:   {build_dir}")
    print(f"  Jobs:        {args.jobs}")
    if args.brute:
        print(f"  Brute-force: enabled")
    print("=" * 73)

    # ---- Step 1: training ----
    if args.train_cmd:
        print("\n=== [1/4] Training: instrumented build + run ===")
        if is_rustc:
            stage2_bin = os.path.join(build_dir, HOST_TRIPLE, "stage2", "bin", "rustc")
            if not os.access(stage2_bin, os.X_OK):
                print("Building instrumented stage2 compiler...")
                env = {"RUSTFLAGS_NOT_BOOTSTRAP": f"-Cprofile-generate={pgo_dir}"}
                r = subprocess.run(
                    [sys.executable, os.path.join(SRC_DIR, "x.py"),
                     "build", "--stage", "2", "library/std", "compiler/rustc",
                     "--build-dir", build_dir, "-j", str(args.jobs)],
                    env={**os.environ, **env})
                if r.returncode != 0:
                    sys.exit("instrumented build failed")
            else:
                print("  (cached instrumented compiler)")
            train_env = os.environ.copy()
            train_env["RUSTC"] = stage2_bin
            train_env["CARGO"] = shutil.which("cargo") or ""
            train_env["RUSTFLAGS"] = f"-Cprofile-generate={pgo_dir}"
        else:
            print("Building instrumented project binaries...")
            train_env = os.environ.copy()
            train_env["RUSTFLAGS"] = (train_env.get("RUSTFLAGS", "")
                                      + f" -Cprofile-generate={pgo_dir}")
            r = subprocess.run(["cargo", "build", "--release",
                                "--target-dir", os.path.join(build_dir, "target")],
                               cwd=project_dir, env=train_env)
            if r.returncode != 0:
                sys.exit("instrumented cargo build failed")
            train_env["RUSTFLAGS"] += f" -Cprofile-generate={pgo_dir}"

        print("Running training command...")
        with open(os.path.join(build_dir, "train.cmd"), "w") as f:
            f.write(args.train_cmd + "\n")
        with open(os.path.join(build_dir, "train.stdout"), "w") as fout, \
             open(os.path.join(build_dir, "train.stderr"), "w") as ferr:
            r = subprocess.run(["bash", "-lc", args.train_cmd],
                               env=train_env, stdout=fout, stderr=ferr)
        if r.returncode != 0:
            print(f"  Training exited with code {r.returncode} (continuing)")

        print("Merging profiles...")
        profraw = glob.glob(os.path.join(pgo_dir, "*.profraw"))
        if not profraw:
            sys.exit(f"no .profraw files in {pgo_dir}")
        merged = os.path.join(pgo_dir, "merged.profdata")
        subprocess.run([llvm_pd, "merge", "-o", merged] + profraw, check=True)
        profdata = merged
        print(f"  Merged: {os.path.getsize(profdata)} bytes")

    # ---- Step 2: generate configs ----
    print("\n=== [2/4] Generating upstream configs ===")
    crate_opt, cargo_env = generate_configs(
        profdata, llvm_pd, known_crates, fn_attrs_csv, crate_list,
        args.hot_div, args.warm_div, args.tepid_div, args.o3_everything)
    shutil.copy(crate_list, opt_best)
    os.environ.update(cargo_env)

    # ---- Step 3: build ----
    print("\n=== [3/4] Building optimised binary ===")

    def build_wrapper(profdata, fn_attrs_csv, extra_env=None, extra_targets=None, lto_off=False):
        if is_rustc:
            return xpy_build_rustc(build_dir, profdata, fn_attrs_csv,
                                   targets=extra_targets or ["library/std", "compiler/rustc"],
                                   jobs=args.jobs, extra_env=extra_env, lto_off=lto_off)
        else:
            return cargo_build_project(project_dir, build_dir, profdata, fn_attrs_csv,
                                       extra_env=extra_env, jobs=args.jobs)

    def measure_fn(build_dir):
        if is_rustc:
            p = rustc_binary(build_dir)
        else:
            p = project_binary_path(project_dir, build_dir)
        if p and os.path.isfile(p):
            return os.path.getsize(p), sha256(p)
        return None

    start = time.time()
    ok = build_wrapper(profdata, fn_attrs_csv)
    elapsed = time.time() - start
    if not ok:
        sys.exit("build failed")

    result = measure_fn(build_dir)
    if result:
        sz, h = result
        print(f"\nBuild complete ({elapsed:.0f}s)")
        print(f"  Binary: {sz} bytes ({sz // 1048576} MB)")
        print(f"  sha256: {h}")
        with open(os.path.join(build_dir, "build-result.csv"), "w") as f:
            f.write("unix_ts,build_time_s,size_bytes,sha256\n")
            f.write(f"{int(time.time())},{elapsed:.0f},{sz},{h}\n")
    else:
        print(f"\nBuild complete ({elapsed:.0f}s, no binary found)")

    if not args.brute:
        print(f"\nDone. Results in {build_dir}")
        return

    # ---- Step 4: brute-force ----
    print("\n=== [4/4] Brute-force per-crate opt-level search ===")
    print(f"  Log: {results_log}")

    def rebuild_fn(profdata, fn_attrs_csv, extra_env=None, extra_targets=None):
        return build_wrapper(profdata, fn_attrs_csv, extra_env=extra_env,
                             extra_targets=extra_targets, lto_off=True)

    def rebuild_crate_fn(crate, build_dir):
        if is_rustc:
            force_rebuild_rustc_crate(crate, build_dir)

    run_brute_loop(crate_list, opt_best, state_file, results_log, build_dir,
                   rebuild_fn, measure_fn, rebuild_crate_fn,
                   profdata, fn_attrs_csv, crate_opt, args.jobs)

    # final full build
    print("\nBuilding final binary with full targets...")
    ok = build_wrapper(profdata, fn_attrs_csv)
    if ok:
        result = measure_fn(build_dir)
        if result:
            sz, h = result
            print(f"\nFINAL: {sz} bytes ({sz // 1048576} MB) sha256: {h}")

    print(f"\nResults in {build_dir}:")
    for fn in ["fn_attrs.csv", "crate_list.txt", "crate_opt_best.txt", "brute-results.csv", "build-result.csv"]:
        p = os.path.join(build_dir, fn)
        if os.path.isfile(p):
            print(f"  {fn}")

if __name__ == "__main__":
    main()
