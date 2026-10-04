"""Guided DP-mode touch tour: captures HID + polls OpenVR controller state, one log.

Usage (with Business StreamingDP running in DP mode, headset worn):
    uv run --quiet python touchtour.py [seconds] [out.log]

Follow the printed prompts.  The log interleaves:
    #   anchor line
    H <t> <type> <len> <hex>       HID report
    O <t> <idx> <pressed> <touched> <ax0x> <ax0y> <ax1>   OpenVR controller state
    I <t> <text>                   tour prompt marker
"""

import ctypes, os, sys, threading, time

HIDAPI = r"D:\Program Files\BusinessStreaming\BusinessStreamingDP\driver\bin\win64\hidapi.dll"
OVRDLL = r"D:\Program Files\BusinessStreaming\BusinessStreamingDP\driver\bin\win64\openvr_api.dll"
VID, PID = 0x2D40, 0x0016
VER = b"IVRSystem_026"
IDX_GET_CLASS, IDX_IS_CONNECTED, IDX_GET_STATE_POSE = 20, 21, 38

TOUR = [
    (6, 14, "baseline: touch nothing"),
    (14, 22, "RIGHT: rest finger on TRIGGER (do not press)"),
    (22, 30, "RIGHT: rest finger on A (do not press)"),
    (30, 38, "RIGHT: rest finger on B (do not press)"),
    (38, 46, "RIGHT: rest finger on JOYSTICK TOP (do not push)"),
    (46, 54, "RIGHT: lightly HOLD grip"),
    (54, 62, "LEFT: rest finger on TRIGGER (do not press)"),
    (62, 70, "LEFT: rest finger on X (do not press)"),
    (70, 78, "LEFT: rest finger on Y (do not press)"),
    (78, 86, "LEFT: rest finger on JOYSTICK TOP (do not push)"),
    (86, 94, "LEFT: lightly HOLD grip"),
    (94, 102, "RIGHT: rest finger on THUMBREST area (above joystick)"),
    (102, 110, "RIGHT: FULLY PRESS A"),
    (110, 118, "RIGHT: FULLY PULL TRIGGER"),
    (118, 126, "RIGHT: rest finger on trigger AGAIN (do not press)"),
]


class Axis(ctypes.Structure):
    _fields_ = [("x", ctypes.c_float), ("y", ctypes.c_float)]


class State(ctypes.Structure):
    _fields_ = [
        ("unPacketNum", ctypes.c_uint32),
        ("ulButtonPressed", ctypes.c_uint64),
        ("ulButtonTouched", ctypes.c_uint64),
        ("rAxis", Axis * 5),
    ]


def open_openvr(log):
    try:
        vr = ctypes.CDLL(OVRDLL)
        vr.VR_IsRuntimeInstalled.restype = ctypes.c_bool
        vr.VR_InitInternal2.restype = ctypes.c_int32
        vr.VR_InitInternal2.argtypes = [
            ctypes.POINTER(ctypes.c_int32),
            ctypes.c_int32,
            ctypes.c_char_p,
        ]
        vr.VR_GetGenericInterface.restype = ctypes.c_void_p
        vr.VR_GetGenericInterface.argtypes = [
            ctypes.c_char_p,
            ctypes.POINTER(ctypes.c_int32),
        ]
        err = ctypes.c_int32(0)
        vr.VR_InitInternal2(ctypes.byref(err), 3, b"")
        if err.value != 0:
            log("I 0 OpenVR init failed err=%d (SteamVR running?)" % err.value)
            return None
        iface = vr.VR_GetGenericInterface(VER, ctypes.byref(err))
        if not iface or err.value != 0:
            log("I 0 OpenVR interface failed err=%d" % err.value)
            return None
        ent = ctypes.cast(
            ctypes.cast(iface, ctypes.POINTER(ctypes.c_void_p))[0],
            ctypes.POINTER(ctypes.c_void_p),
        )
        get_class = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_uint32)(
            ent[IDX_GET_CLASS]
        )
        is_conn = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_uint32)(
            ent[IDX_IS_CONNECTED]
        )
        get_state = ctypes.CFUNCTYPE(
            ctypes.c_bool,
            ctypes.c_void_p,
            ctypes.c_int32,
            ctypes.c_uint32,
            ctypes.POINTER(State),
            ctypes.c_uint32,
            ctypes.c_void_p,
        )(ent[IDX_GET_STATE_POSE])
        idxs = [i for i in range(64) if get_class(iface, i) == 2 and is_conn(iface, i)]
        log("I 0 OpenVR ok, controllers=%s" % idxs)
        if not idxs:
            return None
        return (vr, iface, get_state, idxs)
    except Exception as e:
        log("I 0 OpenVR exception %r" % (e,))
        return None


def main():
    total = float(sys.argv[1]) if len(sys.argv) > 1 else 130.0
    out = sys.argv[2] if len(sys.argv) > 2 else "tour.log"
    f = open(out, "w", encoding="utf-8", buffering=1)
    lock = threading.Lock()
    t0 = time.time()

    def log(line):
        with lock:
            f.write(line + "\n")

    log("# %s secs=%s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), total))

    hid = ctypes.CDLL(HIDAPI)
    hid.hid_init.restype = ctypes.c_int
    hid.hid_open.restype = ctypes.c_void_p
    hid.hid_open.argtypes = [ctypes.c_ushort, ctypes.c_ushort, ctypes.c_wchar_p]
    hid.hid_close.argtypes = [ctypes.c_void_p]
    dev = hid.hid_open(VID, PID, None)
    if not dev:
        print("ERROR: hid_open failed - is the headset in DP streaming mode?")
        return 1
    hid.hid_read_timeout.restype = ctypes.c_int
    hid.hid_read_timeout.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_size_t,
        ctypes.c_int,
    ]

    stop = threading.Event()

    def hid_thread():
        buf = ctypes.create_string_buffer(64)
        while not stop.is_set():
            n = hid.hid_read_timeout(dev, buf, 64, 200)
            if n > 0:
                log(
                    "H %.4f %d %d %s"
                    % (time.time() - t0, buf.raw[2] >> 5, n, buf.raw[:n].hex())
                )

    threading.Thread(target=hid_thread, daemon=True).start()

    ovr = open_openvr(log)
    if ovr:

        def ovr_thread():
            _, iface, get_state, idxs = ovr
            last = {}
            while not stop.is_set():
                for d in idxs:
                    st = State()
                    get_state(iface, 1, d, ctypes.byref(st), ctypes.sizeof(st), None)
                    key = (st.ulButtonPressed, st.ulButtonTouched)
                    if last.get(d) != key:
                        last[d] = key
                        log(
                            "O %.4f %d 0x%016X 0x%016X %.3f %.3f %.3f"
                            % (
                                time.time() - t0,
                                d,
                                st.ulButtonPressed,
                                st.ulButtonTouched,
                                st.rAxis[0].x,
                                st.rAxis[0].y,
                                st.rAxis[1].x,
                            )
                        )
                time.sleep(0.02)

        threading.Thread(target=ovr_thread, daemon=True).start()

    for a, b, txt in TOUR:
        if a >= total:
            break
        w = a - (time.time() - t0)
        if w > 0:
            time.sleep(w)
        print("[%3d-%3ds] %s" % (a, min(b, int(total)), txt), flush=True)
        log("I %.4f %s" % (time.time() - t0, txt))
    while time.time() - t0 < total:
        time.sleep(0.2)
    stop.set()
    time.sleep(0.4)
    f.close()
    hid.hid_close(dev)
    print("saved:", out, os.path.getsize(out), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
