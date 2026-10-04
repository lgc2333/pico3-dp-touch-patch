"""Read the live controller component handles out of vrserver.exe.

Answers two open questions at once:
  1. Is [controller + 0x1f8] (/input/trigger/touch) non-zero?  (0 => CreateBooleanComponent failed)
  2. Which path runs: [*(drv+0x2a8)+0x319] == 0 -> path A, else path B (path B also writes +0x1f8).

Usage:  uv run --quiet python memread.py            (vrserver.exe must be running)
        uv run --quiet python memread.py --dump 0x1f8 0x138 0x148 0x150 0x160 0x1b0 0x190

Layout recap (image base 0x180000000, .data VA 0x9a000 size 0x8c04):
  driver object: +0x2a8 / +0x2b0 / +0x2b8 / +0x2c0 = pointers
                 +0x2b8 + hand*8 = controller object for that hand
  controller:    +0x138 container handle, +0x140 menu click, +0x148 trigger click,
                 +0x150 joystick|trackpad click, +0x160 trigger value, +0x178 grip click,
                 +0x180 system click, +0x190 joystick touch, +0x1a8 grip value,
                 +0x1b0 grip touch, +0x1f8 trigger/touch
  gates:         *(drv+0x2a8)+0x319  (0 => path A)   *(drv+0x2b0)+0x21c (!=0 => input update runs)
"""

import ctypes, ctypes.wintypes as wt, struct, sys

K32 = ctypes.WinDLL("kernel32", use_last_error=True)
PSAPI = ctypes.WinDLL("psapi", use_last_error=True)


class MODULEINFO(ctypes.Structure):
    _fields_ = [
        ("lpBaseOfDll", ctypes.c_void_p),
        ("SizeOfImage", wt.DWORD),
        ("EntryPoint", ctypes.c_void_p),
    ]


PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010

MODULE = "driver_pico.dll"
IMG = 0x180000000
DATA_VA, DATA_SIZE = 0x9A000, 0x8C04
G_DRVINPUT_RVA = 0xA2B40  # DAT_1800a2b40 = IVRDriverInput_003*

k32_open = K32.OpenProcess
k32_open.restype = wt.HANDLE
k32_open.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
K32.ReadProcessMemory.restype = wt.BOOL
K32.ReadProcessMemory.argtypes = [
    wt.HANDLE,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t),
]


def pids(name):
    """All PIDs whose image name matches (case-insensitive)."""
    out, arr, n = [], (wt.DWORD * 4096)(), wt.DWORD()
    if not PSAPI.EnumProcesses(arr, ctypes.sizeof(arr), ctypes.byref(n)):
        return out
    for i in range(n.value // ctypes.sizeof(wt.DWORD)):
        h = k32_open(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, arr[i])
        if not h:
            continue
        buf = ctypes.create_unicode_buffer(1024)
        if (
            PSAPI.GetModuleBaseNameW(h, None, buf, 1024)
            and buf.value.lower() == name.lower()
        ):
            out.append(arr[i])
        K32.CloseHandle(h)
    return out


def modules(pid):
    """[(base, size, name)] for a process."""
    h = k32_open(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
    if not h:
        raise OSError("OpenProcess failed: %d" % ctypes.get_last_error())
    arr, need = (wt.HMODULE * 2048)(), wt.DWORD()
    if not PSAPI.EnumProcessModulesEx(
        h, arr, ctypes.sizeof(arr), ctypes.byref(need), 0x03
    ):
        K32.CloseHandle(h)
        raise OSError("EnumProcessModulesEx failed")
    res = []
    for i in range(need.value // ctypes.sizeof(wt.HMODULE)):
        hm = wt.HMODULE(arr[i])
        base = ctypes.cast(hm, ctypes.c_void_p).value
        buf = ctypes.create_unicode_buffer(1024)
        PSAPI.GetModuleBaseNameW(h, hm, buf, 1024)
        info = MODULEINFO()
        PSAPI.GetModuleInformation(h, hm, ctypes.byref(info), ctypes.sizeof(info))
        res.append((base, info.SizeOfImage, buf.value))
    K32.CloseHandle(h)
    return res


def main():
    args = sys.argv[1:]
    offs = [0x1F8]
    if "--dump" in args:
        offs = [int(x, 16) for x in args[args.index("--dump") + 1 :]]

    found = pids("vrserver.exe")
    if not found:
        print("vrserver.exe not running — start SteamVR first.")
        return 1
    pid = found[0]
    print("vrserver.exe pid = %d" % pid)

    h = k32_open(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
    if not h:
        print("OpenProcess failed err=%d (try elevated)" % ctypes.get_last_error())
        return 1

    def rd(addr, size):
        buf = ctypes.create_string_buffer(size)
        got = ctypes.c_size_t()
        if not K32.ReadProcessMemory(
            h, ctypes.c_void_p(addr), buf, size, ctypes.byref(got)
        ):
            return None
        return buf.raw[: got.value]

    def q(addr, size=8):
        b = rd(addr, size)
        return None if b is None or len(b) < size else int.from_bytes(b, "little")

    mods = modules(pid)
    base = next((b for b, s, n in mods if n.lower() == MODULE.lower()), None)
    if base is None:
        print("driver_pico.dll not loaded in vrserver — is DP mode active?")
        print(
            "loaded modules:",
            ", ".join(n for _, _, n in mods if n.lower().endswith(".dll"))[:400],
        )
        return 1
    print("driver_pico.dll base = 0x%X" % base)

    # --- sanity check: the IVRDriverInput_003 global -------------------------
    gi = q(base + G_DRVINPUT_RVA)
    print(
        "DAT_1800a2b40 (IVRDriverInput_003*) = %s" % (("0x%X" % gi) if gi else "NULL/?")
    )
    if gi:
        vt = q(gi)
        in_drv = vt is not None and base <= vt < base + 0x100000
        print(
            "   vtable = %s  %s"
            % (
                ("0x%X" % vt) if vt else "?",
                "(inside driver .rdata -> plausible)"
                if in_drv
                else "(NOT in driver image -> probably wrong address)",
            )
        )

    # --- scan the driver's writable .data for the driver object --------------
    print(
        "\nscanning driver .data for the driver object "
        "(+0x2a8/+0x2b0/+0x2b8/+0x2c0 all look like pointers)..."
    )
    hits = []
    step = 8
    for off in range(0, DATA_SIZE - 0x300, step):
        v = q(base + DATA_VA + off)
        if not v or not (0x10000 < v < 0x7FFFFFFFFFFF):
            continue
        a = q(v + 0x2A8)
        b = q(v + 0x2B0)
        c = q(v + 0x2B8)
        d = q(v + 0x2C0)
        if not all(x and 0x10000 < x < 0x7FFFFFFFFFFF for x in (a, b, c, d)):
            continue
        # controller objects should carry small component handles
        h138, h148, h160, h1f8 = q(c + 0x138), q(c + 0x148), q(c + 0x160), q(c + 0x1F8)
        if h138 is None:
            continue
        small = [x for x in (h138, h148, h160, h1f8) if x is not None and x < 0x100000]
        if len(small) < 3:
            continue
        hits.append((off, v, a, b, c, d, h138, h148, h160, h1f8))

    print("candidates: %d" % len(hits))
    for off, v, a, b, c, d, h138, h148, h160, h1f8 in hits:
        print("\n--- candidate @ .data+0x%X  drv=0x%X" % (off, v))
        print(
            "    drv+0x2a8=0x%X  drv+0x2b0=0x%X  drv+0x2b8=0x%X(ctrl L)  drv+0x2c0=0x%X(ctrl R)"
            % (a, b, c, d)
        )
        print(
            "    gate [+0x319] = %s   input-enable [+0x21c] = %s"
            % (q(a + 0x319, 1), q(b + 0x21C, 1))
        )
        for hand, ctrl in (("L", c), ("R", d)):
            print("  [%s] ctrl=0x%X" % (hand, ctrl))
            for o in offs:
                print("      +0x%03X = %s" % (o, q(ctrl + o)))
    if not hits:
        print(
            "no candidate found — widen the scan or check the offsets against 02-pc-driver.md"
        )
    K32.CloseHandle(h)
    return 0


if __name__ == "__main__":
    sys.exit(main())
