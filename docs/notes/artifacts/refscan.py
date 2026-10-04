"""Scan the DP driver binary for RIP-relative references to a given VA."""

import sys, struct

P = r"D:\Program Files\BusinessStreaming\BusinessStreamingDP\driver\bin\win64\driver_pico.dll"
IMG = 0x180000000
TEXT_VA, TEXT_RAW, TEXT_SIZE = 0x1000, 0x400, None

b = open(P, "rb").read()

# PE section table
pe = struct.unpack_from("<I", b, 0x3C)[0]
nsec = struct.unpack_from("<H", b, pe + 6)[0]
opt = struct.unpack_from("<H", b, pe + 20)[0]
sizes = struct.unpack_from("<H", b, pe + 20 - 2 + 2)[0]
secs = []
for i in range(nsec):
    o = pe + 24 + opt + i * 40
    name = b[o : o + 8].rstrip(b"\0").decode()
    vsz, va, rsz, raw = struct.unpack_from("<IIII", b, o + 8)
    secs.append((name, va, vsz, raw, rsz))
print("sections:", [(n, hex(v), hex(r)) for n, v, s, r, z in secs])


def va_of(off):
    for name, va, vsz, raw, rsz in secs:
        if raw <= off < raw + rsz:
            return IMG + va + (off - raw), name
    return None, None


def off_of(va):
    for name, va_, vsz, raw, rsz in secs:
        if va_ <= va < va_ + vsz:
            return raw + (va - va_)
    return None


# candidates: (opcode bytes, instruction length incl disp32)
CANDS = [
    (b"\x8b\x05", 6),
    (b"\x48\x8b\x05", 7),  # mov eax/rax,[rip+d]
    (b"\x8d\x05", 6),
    (b"\x48\x8d\x05", 7),  # lea
    (b"\x3b\x05", 6),
    (b"\x39\x05", 6),  # cmp
    (b"\x03\x05", 6),
    (b"\x2b\x05", 6),
    (b"\x85\x05", 6),  # test
    (b"\x83\x3d", 7),
    (b"\x81\x3d", 10),  # cmp [rip+d], imm8/32
    (b"\x0f\xb6\x05", 7),
    (b"\x0f\xbf\x05", 7),  # movzx/movsx
    (b"\xff\x05", 6),
    (b"\xff\x0d", 6),  # inc/dec
    (b"\xc7\x05", 10),  # mov dword [rip+d], imm32
]

targets = {}
for a in sys.argv[1:]:
    targets[int(a, 16)] = []

for name, va, vsz, raw, rsz in secs:
    if name not in (".text",):
        continue
    for off in range(raw, raw + rsz):
        for op, ln in CANDS:
            if b[off : off + len(op)] != op:
                continue
            d = struct.unpack_from("<i", b, off + len(op))[0]
            nxt, _ = va_of(off + ln)
            if nxt is None:
                continue
            t = nxt + d
            if t in targets:
                targets[t].append((off, va_of(off)[0], op.hex(), ln))

for t, hits in targets.items():
    print(f"=== refs to {t:#x} : {len(hits)} ===")
    for off, rva, op, ln in sorted(set(hits)):
        print(f"  file {off:#08x}  rva {rva:#010x}  op {op} len{ln}")
