"""Analyze btour.py output: per window, per report type, which control bytes changed."""

import collections, sys

TOUR = [
    (6, 12, "baseline"),
    (12, 20, "R A press"),
    (20, 28, "R B press"),
    (28, 36, "R joystick press"),
    (36, 44, "R trigger pull"),
    (44, 52, "R system"),
    (52, 60, "L X press"),
    (60, 68, "L Y press"),
    (68, 76, "L joystick press"),
    (76, 84, "L trigger pull"),
    (84, 92, "L system"),
    (92, 98, "release all"),
]

path = sys.argv[1] if len(sys.argv) > 1 else "btour.log"
rows = []
for line in open(path):
    if line.startswith("#"):
        continue
    p = line.rstrip().split("\t")
    if len(p) < 4:
        continue
    b = bytes.fromhex(p[3])
    if len(b) == 64:
        rows.append((float(p[0]), int(p[1]), b))
print(
    "reports:", len(rows), " types:", dict(collections.Counter(t for _, t, _ in rows))
)

for ty in (0, 1, 2):
    base = [b for t, tt, b in rows if tt == ty and 6 <= t < 12]
    if not base:
        continue
    # control-like = byte has few distinct values in baseline
    ctrl = [o for o in range(3, 64) if len(set(x[o] for x in base)) <= 2]
    print("\n" + "#" * 12, "type", ty, "control-like offsets:", ctrl)
    print("   baseline:", {o: sorted(set(x[o] for x in base)) for o in ctrl})
    for a, c, name in TOUR:
        if name == "baseline":
            continue
        sel = [b for t, tt, b in rows if tt == ty and a <= t < c]
        if not sel:
            continue
        hits = []
        for o in ctrl:
            vs = set(x[o] for x in sel)
            bs = set(x[o] for x in base)
            if not vs <= bs:
                hits.append((o, sorted(vs - bs)[:5]))
        if hits:
            print("  %-16s %s" % (name, hits))
