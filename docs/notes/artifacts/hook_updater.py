#!/usr/bin/env python3
"""Hook the transplanted updater inside the live DP driver and log its inputs.

Our update stub calls v2's updater (relocated into the driver's `.pitouch`
section) as

    updater(rcx = &scratch[hand], edx = v2 mask, xmm2 = trigger, xmm3 = grip)

so hooking that entry shows exactly what the driver feeds the v2 algorithm --
including the bits the driver's own latch state cannot show (the click bits,
which v2's pose selection also reads).

    uv run --with frida python temp/driver_port/hook_updater.py [seconds]

Prints one line per *change* of (mask, trigger, grip), plus a heartbeat with the
call rate, so a still controller shows the idle mask.
"""

import sys
import time
from ctypes import wintypes

import frida
import psutil

UPDATER_RVA = 0xB96D0  # 0x1800b96d0 - 0x180000000 (see build_dp_skeleton_payload.py)
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010

k32 = None


def find_vrserver():
    for p in psutil.process_iter(["name", "pid"]):
        if (p.info["name"] or "").lower() == "vrserver.exe":
            return p.info["pid"]
    return None


def module_base(pid, needle="driver_pico.dll"):
    import ctypes

    global k32
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    psapi.EnumProcessModulesEx.argtypes = [
        wintypes.HANDLE,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        wintypes.DWORD,
    ]
    psapi.EnumProcessModulesEx.restype = wintypes.BOOL
    psapi.GetModuleFileNameExW.argtypes = [
        wintypes.HANDLE,
        wintypes.HMODULE,
        wintypes.LPWSTR,
        wintypes.DWORD,
    ]
    psapi.GetModuleFileNameExW.restype = wintypes.DWORD
    h = k32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
    if not h:
        raise OSError(ctypes.get_last_error())
    try:
        mods = (wintypes.HMODULE * 1024)()
        need = ctypes.c_ulong(0)
        if not psapi.EnumProcessModulesEx(
            h, ctypes.byref(mods), ctypes.sizeof(mods), ctypes.byref(need), 3
        ):
            raise OSError(ctypes.get_last_error())
        n = need.value // ctypes.sizeof(wintypes.HMODULE)
        for i in range(n):
            buf = ctypes.create_unicode_buffer(1024)
            if psapi.GetModuleFileNameExW(h, mods[i], buf, 1024):
                if buf.value.lower().endswith(needle):
                    return int(mods[i])
        return None
    finally:
        k32.CloseHandle(h)


SCRIPT = """
const updater = ptr('%s');
const forceMask = %s;
let last = null, count = 0, t0 = Date.now();Interceptor.attach(updater, {
  onEnter(args) {
    count++;
    if (forceMask >= 0) args[1] = ptr(forceMask);
    const scratch = args[0];
    const mask = args[1].toInt32() & 0xffff;
    let trig = 0, grip = 0;
    try {
      trig = this.context.xmm2.readFloat();
      grip = this.context.xmm3.readFloat();
    } catch (e) {}
    const hand = scratch.add(0xE8).readU32();
    const key = mask + '|' + trig.toFixed(3) + '|' + grip.toFixed(3) + '|' + hand;
    if (key !== last) {
      last = key;
      send({kind: 'change', hand: hand, mask: mask, trig: trig, grip: grip, calls: count});
    }
  }
});
setInterval(() => {
  send({kind: 'beat', calls: count, hz: count / ((Date.now() - t0) / 1000)});
}, 2000);
"""


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    force = sys.argv[2] if len(sys.argv) > 2 else "-1"
    force_mask = int(force, 0) if force != "-1" else -1
    pid = find_vrserver()
    if pid is None:
        print("vrserver.exe is not running")
        return 1
    base = module_base(pid)
    if base is None:
        print("driver_pico.dll is not loaded")
        return 1
    entry = base + UPDATER_RVA
    print(f"vrserver pid={pid} base={base:#x} updater={entry:#x} force_mask={force_mask}")
    session = frida.attach(pid)
    script = session.create_script(SCRIPT % (hex(entry), force_mask))

    def on_message(message, data):
        if message["type"] != "send":
            print("script:", message)
            return
        p = message["payload"]
        if p["kind"] == "change":
            print(
                f"  hand{p['hand']} mask={p['mask']:#06x} trig={p['trig']:.3f} "
                f"grip={p['grip']:.3f}  (calls so far {p['calls']})",
                flush=True,
            )
        else:
            print(f"  [{p['calls']} calls, {p['hz']:.0f} Hz]", flush=True)

    script.on("message", on_message)
    script.load()
    time.sleep(seconds)
    session.detach()
    return 0


if __name__ == "__main__":
    sys.exit(main())
