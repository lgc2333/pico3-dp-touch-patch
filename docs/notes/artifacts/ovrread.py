"""Plain OpenVR monitor: prints controller state every 250 ms for N seconds.

Usage: ovrread.py [seconds] [out.log]
Run it with a uniquely-named python.exe so SteamVR does not throttle binding loads.
"""

import ctypes, sys, time

OVRDLL = r"D:\Program Files\BusinessStreaming\BusinessStreamingDP\driver\bin\win64\openvr_api.dll"
VER = b"IVRSystem_026"
IDX_GET_CLASS, IDX_IS_CONNECTED, IDX_GET_STATE = 20, 21, 37
NAMES = {
    0: "System",
    1: "AppMenu",
    2: "Grip",
    7: "A/X",
    31: "Proximity",
    32: "Axis0/Joy",
    33: "Axis1/Trig",
    34: "Axis2",
    35: "Axis3",
    36: "Axis4",
}


class Axis(ctypes.Structure):
    _fields_ = [("x", ctypes.c_float), ("y", ctypes.c_float)]


class State(ctypes.Structure):
    _fields_ = [
        ("unPacketNum", ctypes.c_uint32),
        ("ulButtonPressed", ctypes.c_uint64),
        ("ulButtonTouched", ctypes.c_uint64),
        ("rAxis", Axis * 5),
    ]


def bits(m, n=40):
    return ",".join(str(i) for i in range(n) if m & (1 << i)) or "-"


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 40.0
    out = sys.argv[2] if len(sys.argv) > 2 else "ovrread.log"
    f = open(out, "w", encoding="utf-8", buffering=1)

    vr = ctypes.CDLL(OVRDLL)
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
        print("init failed err=%d" % err.value)
        return 1
    iface = vr.VR_GetGenericInterface(VER, ctypes.byref(err))
    if not iface or err.value != 0:
        print("iface failed err=%d" % err.value)
        return 1
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
        ctypes.c_uint32,
        ctypes.POINTER(State),
        ctypes.c_uint32,
    )(ent[IDX_GET_STATE])
    idxs = [i for i in range(64) if get_class(iface, i) == 2 and is_conn(iface, i)]
    print("controllers:", idxs, " watching %.0fs" % secs)
    f.write(
        "# ovrread %s controllers=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), idxs)
    )

    t0 = time.time()
    while time.time() - t0 < secs:
        parts = []
        for d in idxs:
            s = State()
            ok = get_state(iface, d, ctypes.byref(s), ctypes.sizeof(s))
            parts.append(
                "c%d ok=%d P=0x%X[%s] T=0x%X[%s] trig=%.2f joy=%.2f,%.2f"
                % (
                    d,
                    ok,
                    s.ulButtonPressed,
                    bits(s.ulButtonPressed),
                    s.ulButtonTouched,
                    bits(s.ulButtonTouched),
                    s.rAxis[1].x,
                    s.rAxis[0].x,
                    s.rAxis[0].y,
                )
            )
        line = "t=%6.2f  %s" % (time.time() - t0, "  |  ".join(parts))
        print(line, flush=True)
        f.write(line + "\n")
        time.sleep(0.25)
    f.close()
    print("saved:", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
