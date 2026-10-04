"""Message-type histogram and timeline for the PICO HID stream (type = report[2] >> 5)."""

import sys
from collections import Counter

path = sys.argv[1] if len(sys.argv) > 1 else "act2.log"
rows = []
for line in open(path, encoding="utf-8"):
    if line.startswith("#"):
        continue
    p = line.rstrip("\n").split("\t")
    if len(p) != 4:
        continue
    rows.append((float(p[0]), bytes.fromhex(p[3])))

print(f"reports={len(rows)}")
print("type histogram:", Counter(b[2] >> 5 for _, b in rows).most_common())
print("byte1 histogram:", Counter(b[1] for _, b in rows).most_common(10))
print("byte2 histogram:", Counter(b[2] for _, b in rows).most_common(20))

seq = []
for t, b in rows:
    key = (b[1], b[2] >> 5)
    if not seq or seq[-1][1] != key:
        seq.append((t, key))
print(f"\ntype/flag transitions={len(seq)}")
for t, k in seq[:80]:
    print(f"{t:9.3f}  byte1={k[0]:#04x} type={k[1]}")
