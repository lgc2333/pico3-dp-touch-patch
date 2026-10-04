"""Read the live pico controller component handles out of vrserver.exe.

Driver object is the static global at RVA 0x9AD10 (confirmed in IDA: 16 lea xrefs,
first qword = vtable 0x18008C7D8), i.e. param_1 of sub_18003D610 / sub_180019580.

  drv = base + 0x9AD10
  drv+0x2a8 -> object with +0x319  (0 => path A, else path B)
  drv+0x2b0 -> object with +0x21c  (!=0 => input update runs)
  drv+0x2b8 -> left  controller object
  drv+0x2c0 -> right controller object
  ctrl+0x130 == -1 => sub_180019580 bails immediately
  ctrl+0x1f8 = /input/trigger/touch handle   <-- the question: is it 0?

Usage: uv run --quiet python readhandles.py [--watch SECONDS]
"""

import ctypes, ctypes.wintypes as wt, sys, time

K32 = ctypes.WinDLL("kernel32", use_last_error=True)
PSAPI = ctypes.WinDLL("psapi", use_last_error=True)
K32.OpenProcess.restype = wt.HANDLE
K32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
K32.ReadProcessMemory.argtypes = [
    wt.HANDLE,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t),
]

DRV_RVA = 0x9AD10
OFFS = [
    (0x130, "(int) -1 => bail"),
    (0x138, "container"),
    (0x140, "application_menu/click"),
    (0x148, "trigger/click"),
    (0x150, "joystick|trackpad/click"),
    (0x158, "trackpad/touch"),
    (0x160, "trigger/value"),
    (0x168, "trackpad/x"),
    (0x170, "trackpad/y"),
    (0x178, "grip/click"),
    (0x180, "system/click"),
    (0x190, "joystick/touch"),
    (0x198, "joystick/x"),
    (0x1A0, "joystick/y"),
    (0x1A8, "grip/value"),
    (0x1B0, "grip/touch"),
    (0x1B8, "x/click"),
    (0x1C0, "x/touch"),
    (0x1C8, "y/click"),
    (0x1D0, "y/touch"),
    (0x1D8, "a/click"),
    (0x1E0, "a/touch"),
    (0x1E8, "b/click"),
    (0x1F0, "b/touch"),
    (0x1F8, "*** trigger/touch ***"),
]


def find_pid(name):
    arr, n = (wt.DWORD * 4096)(), wt.DWORD()
    PSAPI.EnumProcesses(arr, ctypes.sizeof(arr), ctypes.byref(n))
    for i in range(n.value // 4):
        h = K32.OpenProcess(0x410, False, arr[i])
        if not h:
            continue
        b = ctypes.create_unicode_buffer(1024)
        r = PSAPI.GetModuleBaseNameW(h, None, b, 1024) and b.value.lower() == name
        K32.CloseHandle(h)
        if r:
            return arr[i]
    return None


pid = find_pid("vrserver.exe")
if not pid:
    print("vrserver.exe NOT running -> start DP mode + SteamVR first")
    sys.exit(1)
h = K32.OpenProcess(0x410, False, pid)
arr, need = (wt.HMODULE * 4096)(), wt.DWORD()
PSAPI.EnumProcessModulesEx(h, arr, ctypes.sizeof(arr), ctypes.byref(need), 0x03)
base = None
for i in range(need.value // ctypes.sizeof(wt.HMODULE)):
    nm = ctypes.create_unicode_buffer(1024)
    PSAPI.GetModuleBaseNameW(h, wt.HMODULE(arr[i]), nm, 1024)
    if nm.value.lower() == "driver_pico.dll":
        base = ctypes.cast(wt.HMODULE(arr[i]), ctypes.c_void_p).value
        break
if base is None:
    print("driver_pico.dll not loaded in vrserver -> is DP mode active?")
    sys.exit(1)


def q(a, sz=8):
    buf = ctypes.create_string_buffer(sz)
    got = ctypes.c_size_t()
    if not K32.ReadProcessMemory(h, ctypes.c_void_p(a), buf, sz, ctypes.byref(got)):
        return None
    return int.from_bytes(buf.raw[: got.value], "little")


def dump():
    drv = base + DRV_RVA
    print("vrserver pid=%d  driver base=0x%X  driver object=0x%X" % (pid, base, drv))
    print("  vtable = 0x%X  (expect 0x18008C7D8)" % q(drv))
    a, b, cl, cr = q(drv + 0x2A8), q(drv + 0x2B0), q(drv + 0x2B8), q(drv + 0x2C0)
    print("  +0x2a8=0x%X  +0x2b0=0x%X  +0x2b8(L)=0x%X  +0x2c0(R)=0x%X" % (a, b, cl, cr))
    for nm, p in (("2a8", a), ("2b0", b)):
        if p:
            print(
                "     [%s+0x319]=%s   [%s+0x21c]=%s"
                % (nm, q(p + 0x319, 1), nm, q(p + 0x21C, 1))
            )
    for nm, c in (("LEFT", cl), ("RIGHT", cr)):
        if not c:
            continue
        print("  --- %s controller @ 0x%X   hand(+8)=%s" % (nm, c, q(c + 8, 4)))
        for o, lab in OFFS:
            v = q(c + o)
            flag = ""
            if o == 0x1F8:
                flag = (
                    "   <== ZERO => CreateBooleanComponent failed!"
                    if v == 0
                    else "   <== NON-ZERO: handle is valid"
                )
            print("      +0x%03X = %-12s %s%s" % (o, v, lab, flag))


dump()
if "--watch" in sys.argv:
    secs = int(sys.argv[sys.argv.index("--watch") + 1])
    cl, cr = q(base + DRV_RVA + 0x2B8), q(base + DRV_RVA + 0x2C0)
    print(
        "\nwatching +0x1f8 handle for %ds (handles are static; this just proves they don't change)"
        % secs
    )
    t0 = time.time()
    while time.time() - t0 < secs:
        print(
            "t=%5.1f  L=%s  R=%s" % (time.time() - t0, q(cl + 0x1F8), q(cr + 0x1F8)),
            flush=True,
        )
        time.sleep(1)
K32.CloseHandle(h)
