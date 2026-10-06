#!/usr/bin/env python3
"""Symbol-closure analyzer for OrcaBridgeCore.

Extracts every object from the archive, BFS-walks the undefined-symbol graph
from the Bridge root, and reports:
  1. which archive objects are actually reachable (kept set)
  2. which Slic3r:: undefineds remain and which upstream .cpp files define them
  3. which non-Slic3r symbol families remain (external-lib debt)

Usage: closure.py <libOrcaBridgeCore.a> <libslic3r-src-dir> <llvm-nm-path>
"""
import subprocess, sys, os, re, tempfile, shutil, collections

archive, src_dir, nm = sys.argv[1], sys.argv[2], sys.argv[3]
work = tempfile.mkdtemp(prefix="closure-")

# --- extract all objects ---
members = subprocess.run(["ar", "t", archive], capture_output=True, text=True).stdout.split()
for m in members:
    data = subprocess.run(["ar", "p", archive, m], capture_output=True).stdout
    with open(os.path.join(work, m), "wb") as f:
        f.write(data)

# --- symbol tables ---
defs = {}        # symbol -> [object,...] (strong first)
undefs = {}      # object -> [symbol,...]
strong = set()
for m in members:
    out = subprocess.run([nm, os.path.join(work, m)], capture_output=True, text=True).stdout
    u = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == "U":
            u.append(parts[1])
        elif len(parts) == 3 and parts[1] == "U":
            u.append(parts[2])
        elif len(parts) == 3 and parts[1] in ("T", "t", "W", "w", "V", "v", "R", "r", "D", "d", "B", "b", "S", "s"):
            defs.setdefault(parts[2], []).append(m)
            strong.add(parts[2])
        elif len(parts) == 3 and parts[1] in ("W", "w", "D", "d", "B", "b", "S", "s"):
            defs.setdefault(parts[2], []).append(m)
    if u:
        undefs[m] = u

# --- BFS closure from root objects ---
# Accept the former object name while inspecting a pre-migration archive.
roots = [m for m in members if "orca_bridge" in m or "orca_core" in m]
assert roots, "no Bridge root object in archive"
kept, queue, seen = set(roots), list(roots), set(roots)
while queue:
    m = queue.pop()
    for sym in undefs.get(m, []):
        for d in defs.get(sym, []):
            if d not in seen:
                seen.add(d)
                kept.add(d)
                queue.append(d)

# --- remaining undefineds after closure ---
remaining = set()
for m in kept:
    remaining.update(undefs.get(m, []))
remaining -= set(defs.keys())

# --- demangle all at once ---
dem = subprocess.run(["c++filt"], input="\n".join(remaining), capture_output=True, text=True).stdout.splitlines()
pairs = list(zip(remaining, dem))

# --- duplicate audit (Mach-O aware) ---
# Weak external symbols (C++ inline/implicit emissions) coalesce at link;
# llvm-nm's brief format prints them as 'T', so parse `nm -m` detail lines
# and flag ONLY non-weak duplicate definitions.
strong_defs = collections.defaultdict(set)
for m in members:
    out = subprocess.run([nm, "-m", os.path.join(work, m)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "(__TEXT,__text)" not in line:
            continue
        sym = line.split()[-1]
        if "weak" in line or "non-external" in line:
            continue  # coalesced at link / TU-local
        if sym.startswith("___clang_call_terminate") or sym.startswith("_OUTLINED_FUNCTION"):
            continue  # per-TU locals
        if sym.startswith("ltmp") or ".cold." in sym:
            continue  # section labels / cold fragments of weak parents
        strong_defs[sym].add(m)
dups = {s: ms for s, ms in strong_defs.items() if len(ms) > 1}
if dups:
    print(f"== DUPLICATE NON-WEAK SYMBOLS: {len(dups)} ==")
    for s, ms in list(dups.items())[:20]:
        d = subprocess.run(["c++filt"], input=s, capture_output=True, text=True).stdout.strip()
        print(f"  {d}  <- {len(ms)} members: {[x.split('_orcaslicer_')[-1][:50] for x in ms]}")
else:
    print("== duplicate symbol audit (non-weak): CLEAN ==")

slic3r = [(m, d) for m, d in pairs if d.startswith("Slic3r::")]
other = [(m, d) for m, d in pairs if not d.startswith("Slic3r::")]

# --- locate upstream definers for Slic3r undefineds ---
cands = collections.Counter()
cand_syms = collections.defaultdict(list)
for mangled, d in slic3r:
    # strip templates, take the qualified name before '('
    base = re.sub(r"<.*", "", d).split("(")[0].split("::")[:-1] or [d]
    # use the last two components as a grep key: Foo::bar
    comps = re.sub(r"<.*", "", d).split("(")[0].split("::")
    if len(comps) >= 2:
        key = f"{comps[-2]}::{comps[-1]}"
    elif comps:
        key = comps[-1]
    else:
        continue
    r = subprocess.run(["grep", "-rl", "--include=*.cpp", "-F", key, src_dir],
                       capture_output=True, text=True)
    for f in r.stdout.split():
        rel = os.path.relpath(f, src_dir)
        cands[rel] += 1
        cand_syms[rel].append(d[:110])

print(f"== archive objects: {len(members)}, closure-kept: {len(kept)} ==")
print("\n== Slic3r undefineds needing upstream .cpp files ==")
for f, n in sorted(cands.items(), key=lambda kv: -kv[1]):
    print(f"  {f}  ({n} syms, e.g. {cand_syms[f][0]})")
print(f"\n== non-Slic3r external symbols: {len(other)} ==")
fams = collections.Counter()
for m, d in other:
    fam = d.split("<")[0].split("(")[0][:60]
    fams[fam] += 1
for fam, n in fams.most_common(40):
    print(f"  {n:4d}  {fam}")

shutil.rmtree(work)
