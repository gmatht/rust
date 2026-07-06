#!/usr/bin/env python3
"""Generate PGSO10/PGSO100 opt-level files from existing PGSO baseline.

"10x colder to be demoted" means the demotion threshold is 10x more lenient:
more functions stay at O3/O2/Os rather than falling to Oz. We achieve this
by dividing the original threshold values by `factor`, so e.g. the top N% of
functions that qualified as "hot" becomes the top (N*factor)% instead.
"""
import sys

fn_in = sys.argv[1]       # e.g. build/pgo_data/fn_opt_levels.txt
cgu_in = sys.argv[2]      # e.g. build/pgo_data/cgu_opt_levels.txt
fn_out = sys.argv[3]      # output fn file
cgu_out = sys.argv[4]     # output cgu file
factor = float(sys.argv[5])  # 10 for PGSO10, 100 for PGSO100

# Read fn file, keeping level
with open(fn_in) as f:
    lines = [(line.strip(), line.strip().rsplit(None, 1)[-1]) for line in f if line.strip() and not line.startswith("#")]

n_o3 = sum(1 for _, lvl in lines if lvl == "O3")
n_o2 = sum(1 for _, lvl in lines if lvl == "O2")
n_os = sum(1 for _, lvl in lines if lvl == "Os")
total = len(lines)

# Factor applied to counts: more functions stay at each level
new_o3 = min(int(n_o3 * factor), total)
new_o2 = min(int(n_o2 * factor), total - new_o3)
new_os = min(int(n_os * factor), total - new_o3 - new_o2)

print(f"PGSO baseline: {n_o3} O3, {n_o2} O2, {n_os} Os")
print(f"PGSO{factor:.0f}:      {new_o3} O3, {new_o2} O2, {new_os} Os, {total - new_o3 - new_o2 - new_os} Oz")

with open(fn_out, "w") as f:
    for i, (line, lvl) in enumerate(lines):
        if i < new_o3:
            f.write(f"{line.rsplit(None, 1)[0]} O3\n")
        elif i < new_o3 + new_o2:
            f.write(f"{line.rsplit(None, 1)[0]} O2\n")
        elif i < new_o3 + new_o2 + new_os:
            f.write(f"{line.rsplit(None, 1)[0]} Os\n")

# CGU: more crates stay at higher opt levels
with open(cgu_in) as f:
    cgu_lines = [line.strip() for line in f if line.strip() and not line.startswith("#") and not line.startswith(";")]

n_o3_cgu = sum(1 for l in cgu_lines if " O3" in l)
n_o2_cgu = sum(1 for l in cgu_lines if " O2" in l)
n_os_cgu = sum(1 for l in cgu_lines if " Os" in l)

new_o3_cgu = min(int(n_o3_cgu * factor), len(cgu_lines))
new_o2_cgu = min(int(n_o2_cgu * factor), len(cgu_lines) - new_o3_cgu)
new_os_cgu = min(int(n_os_cgu * factor), len(cgu_lines) - new_o3_cgu - new_o2_cgu)

with open(cgu_out, "w") as f:
    f.write("# CGU opt levels (prefix match against crate name)\n")
    written = 0
    # Keep original O3 entries, then promote some O2→O3, Os→O2, etc.
    for i, line in enumerate(cgu_lines):
        name = line.rsplit(None, 1)[0]
        if i < new_o3_cgu:
            f.write(f"{name} O3\n")
        elif i < new_o3_cgu + new_o2_cgu:
            f.write(f"{name} O2\n")
        elif i < new_o3_cgu + new_o2_cgu + new_os_cgu:
            f.write(f"{name} Os\n")
        else:
            f.write(f"{name} Oz\n")
