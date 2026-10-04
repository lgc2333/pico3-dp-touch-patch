"""Guided HID button tour: which report byte/bit carries which button, per hand.

Usage: uv run --quiet python btour.py [seconds] [out.log]
Needs DP streaming active (HID reports flowing). Follow the printed prompts.
"""

import ctypes, os, sys, threading, time

HIDAPI = r"D:\Program Files\BusinessStreaming\BusinessStreamingDP\driver\bin\win64\hidapi.dll"
VID, PID = 0x2D40, 0x0016

TOUR = [
    (6, 12, "baseline: touch nothing"),
    (12, 20, "RIGHT: hold A pressed"),
    (20, 28, "RIGHT: hold B pressed"),
    (28, 36, "RIGHT: hold JOYSTICK pressed down"),
    (36, 44, "RIGHT: pull TRIGGER fully"),
    (44, 52, "RIGHT: hold system/menu button"),
    (52, 60, "LEFT: hold X pressed"),
    (60, 68, "LEFT: hold Y pressed"),
    (68, 76, "LEFT: hold JOYSTICK pressed down"),
    (76, 84, "LEFT: pull TRIGGER fully"),
    (84, 92, "LEFT: hold system/menu button"),
    (92, 98, "release everything"),
]


def main():
    total = float(sys.argv[1]) if len(sys.argv) > 1 else 100.0
    out = sys.argv[2] if len(sys.argv) > 2 else "btour.log"

    hid = ctypes.CDLL(HIDAPI)
    hid.hid_init.restype = ctypes.c_int
    hid.hid_open.restype = ctypes.c_void_p
    hid.hid_open.argtypes = [ctypes.c_ushort, ctypes.c_ushort, ctypes.c_wchar_p]
    hid.hid_close.argtypes = [ctypes.c_void_p]
    dev = hid.hid_open(VID, PID, None)
    if not dev:
        print("ERROR: hid_open failed - DP streaming running?")
        return 1
    hid.hid_read_timeout.restype = ctypes.c_int
    hid.hid_read_timeout.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_size_t,
        ctypes.c_int,
    ]

    f = open(out, "w", encoding="utf-8", buffering=1)
    f.write("# %s secs=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), total))
    t0 = time.time()
    stop = threading.Event()

    def reader():
        buf = ctypes.create_string_buffer(64)
        while not stop.is_set():
            n = hid.hid_read_timeout(dev, buf, 64, 200)
            if n > 0:
                f.write(
                    "%.4f\t%d\t%d\t%s\n"
                    % (time.time() - t0, buf.raw[2] >> 5, n, buf.raw[:n].hex())
                )

    threading.Thread(target=reader, daemon=True).start()
    for a, b, txt in TOUR:
        if a >= total:
            break
        w = a - (time.time() - t0)
        if w > 0:
            time.sleep(w)
        print("[%3d-%3ds] %s" % (a, min(b, int(total)), txt), flush=True)
        f.write("# %s\n" % txt)
    while time.time() - t0 < total:
        time.sleep(0.2)
    stop.set()
    time.sleep(0.3)
    f.close()
    hid.hid_close(dev)
    print("saved:", out, os.path.getsize(out), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
