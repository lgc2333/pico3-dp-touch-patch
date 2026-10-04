"""Analyze a touchtour.py log: per tour window, show HID key-word bits and OpenVR masks."""

import collections, sys

TOUR = [
    (6, 14, "baseline"),
    (14, 22, "R trigger touch"),
    (22, 30, "R A touch"),
    (30, 38, "R B touch"),
    (38, 46, "R joystick touch"),
    (46, 54, "R grip hold"),
    (54, 62, "L trigger touch"),
    (62, 70, "L X touch"),
    (70, 78, "L Y touch"),
    (78, 86, "L joystick touch"),
    (86, 94, "L grip hold"),
    (94, 102, "R thumbrest"),
    (102, 110, "R A press"),
    (110, 118, "R trigger press"),
    (118, 126, "R trigger touch #2"),
]

path = sys.argv[1] if len(sys.argv) > 1 else "tour.log"
hid = []  # (t, type, bytes)
ovr = []  # (t, idx, pressed, touched)
for line in open(path):
    if line.startswith("#"):
        print("anchor:", line.strip())
        continue
    p = line.split()
    if not p:
        continue
    if p[0] == "H":
        b = bytes.fromhex(p[4])
        if len(b) == 64:
            hid.append((float(p[1]), int(p[2]), b))
    elif p[0] == "O":
        ovr.append((float(p[1]), int(p[2]), int(p[3], 16), int(p[4], 16)))
    elif p[0] == "I":
        print("  tour:", " ".join(p[2:]))

print("hid reports:", len(hid), " ovr events:", len(ovr))
types = collections.Counter(t for _, t, _ in hid)
print("hid types:", dict(types))


def bits(mask, n=64):
    return [i for i in range(n) if mask & (1 << i)]


print("\n=== HID key word per window (off50=low, off51=high) ===")
for ty in sorted(types):
    print("\n-- type %d --" % ty)
    base = [b for t, tt, b in hid if 6 <= t < 14 and tt == ty]
    if not base:
        base = [b for t, tt, b in hid if tt == ty][:200]
    b50 = set(x[50] for x in base)
    b51 = set(x[51] for x in base)
    for a, c, name in TOUR:
        sel = [b for t, tt, b in hid if a <= t < c and tt == ty]
        if not sel:
            continue
        c50 = collections.Counter(x[50] for x in sel)
        c51 = collections.Counter(x[51] for x in sel)
        new50 = {k: v for k, v in c50.items() if k not in b50}
        new51 = {k: v for k, v in c51.items() if k not in b51}
        flag = "  <<< CHANGED" if (new50 or new51) else ""
        print(
            "  %-18s n=%5d off50=%s off51=%s%s"
            % (name, len(sel), dict(c50), dict(c51), flag)
        )
        if new50 or new51:
            print("        new off50=%s new off51=%s" % (new50, new51))

print("\n=== OpenVR controller state per window ===")
for idx in sorted(set(i for _, i, _, _ in ovr)):
    print("\n-- controller %d --" % idx)
    for a, c, name in TOUR:
        sel = [o for o in ovr if a <= o[0] < c and o[1] == idx]
        if not sel:
            continue
        pb = set()
        tb = set()
        for _, _, p, t in sel:
            pb |= set(bits(p))
            tb |= set(bits(t))
        print(
            "  %-18s pressed bits=%s touched bits=%s" % (name, sorted(pb), sorted(tb))
        )
