#!/usr/bin/env python3
"""Extract hot functions from LLVM profdata, demangle, generate fn_opt_levels file."""
import subprocess, sys, os, re
from collections import Counter

PROFDATA = "/root/src/rustloop/rust1.96/build/pgo_data/merged.profdata"
LLVM_BIN = "/root/src/rustloop/rust1.96/build-patched/x86_64-unknown-linux-gnu/ci-llvm/bin"
FN_OUT = "/root/src/rustloop/rust1.96/build/pgo_data/fn_opt_levels_prof.txt"

def parse_profdata():
    """Parse llvm-profdata output to get (mangled_name, count) pairs."""
    result = subprocess.run(
        [f"{LLVM_BIN}/llvm-profdata", "show", "--all-functions", PROFDATA],
        capture_output=True, text=True
    )
    entries = []
    current_name = None
    current_count = 0
    
    for line in result.stdout.split('\n'):
        # Lines starting with non-whitespace are function names
        if line and not line.startswith(' ') and not line.startswith('Counters') and not line.startswith('Functions') and not line.startswith('Total') and not line.startswith('Instrumentation') and not line.startswith('Hash') and not line.startswith('  '):
            if current_name:
                entries.append((current_name, current_count))
            # Extract mangled name (after last ';' or the entire line)
            if ';_RN' in line:
                mangled = line.split(';_RN', 1)[1]
                # Remove trailing ':'
                mangled = mangled.rstrip(':')
                current_name = '_RN' + mangled
            else:
                current_name = None
            current_count = 0
        elif 'Counters:' in line:
            try:
                current_count = int(line.split(':')[1].strip())
            except:
                current_count = 0
    
    if current_name:
        entries.append((current_name, current_count))
    
    return entries

def demangle(mangled_name):
    """Demangle using rustfilt."""
    try:
        result = subprocess.run(['rustfilt'], input=mangled_name, 
                              capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else mangled_name
    except FileNotFoundError:
        return mangled_name

def main():
    print("Parsing profdata...", file=sys.stderr)
    entries = parse_profdata()
    print(f"  Found {len(entries)} functions with profile data", file=sys.stderr)
    
    # Filter to only functions with count > 0
    entries = [(n, c) for n, c in entries if c > 0]
    print(f"  {len(entries)} have non-zero count", file=sys.stderr)
    
    if not entries:
        print("ERROR: No functions with count > 0 found!", file=sys.stderr)
        sys.exit(1)
    
    # Sort by count descending
    entries.sort(key=lambda x: -x[1])
    
    max_count = entries[0][1]
    print(f"  Max count: {max_count}", file=sys.stderr)
    print(f"  Min count (of non-zero): {entries[-1][1]}", file=sys.stderr)
    
    # Demangle top entries
    # Take top N where N = min(2000, number of entries)
    top_n = min(2000, len(entries))
    print(f"  Demangling top {top_n}...", file=sys.stderr)
    
    hot_fns = []
    for i, (mangled, count) in enumerate(entries[:top_n]):
        demangled = demangle(mangled)
        if demangled and demangled != mangled:
            hot_fns.append((demangled, count))
        if (i+1) % 500 == 0:
            print(f"    {i+1}/{top_n}...", file=sys.stderr)
    
    print(f"  Successfully demangled: {len(hot_fns)}", file=sys.stderr)
    
    # Assign opt levels based on hotness quartiles
    n = len(hot_fns)
    o3_count = n * 25 // 100
    o2_count = n * 25 // 100
    
    with open(FN_OUT, 'w') as f:
        f.write(f"# Generated from {PROFDATA}\n")
        f.write(f"# Total profiled functions: {len(entries)}\n")
        f.write(f"# Top {n} hottest functions ranked by execution count\n")
        f.write(f"# Opt levels: top 25% O3, next 25% O2, bottom 50% Os\n")
        f.write("\n")
        
        for i, (name, count) in enumerate(hot_fns):
            if i < o3_count:
                opt = "O3"
            elif i < o3_count + o2_count:
                opt = "O2"
            else:
                opt = "Os"
            f.write(f"{name} {opt}\n")
    
    print(f"\nWrote {n} entries to {FN_OUT}", file=sys.stderr)
    
    # Show sample
    from collections import Counter as Cnt
    c = Cnt()
    with open(FN_OUT) as f:
        for line in f:
            if not line.startswith('#'):
                parts = line.strip().rsplit(' ', 1)
                if len(parts) == 2:
                    c[parts[1]] += 1
    print(f"By opt level: {dict(c)}", file=sys.stderr)
    print(f"\nFirst 5 entries:", file=sys.stderr)
    subprocess.run(['head', '-5', FN_OUT])

if __name__ == '__main__':
    main()
