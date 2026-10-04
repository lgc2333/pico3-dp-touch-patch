"""Capture PICO headset HID reports (VID 0x2D40) to a log, then report which bytes move.

usage: uv run python hidcap.py <seconds> <outfile>
"""

import ctypes, sys, time, threading, collections

DLL = r"D:\Program Files\BusinessStreaming\BusinessStreamingDP\driver\bin\win64\hidapi.dll"
dll = ctypes.CDLL(DLL)

HAS_VERSION = hasattr(dll, "hid_version")


class Info13(ctypes.Structure):
    pass


Info13._fields_ = [
    ("path", ctypes.c_char_p),
    ("vendor_id", ctypes.c_ushort),
    ("product_id", ctypes.c_ushort),
    ("serial_number", ctypes.c_wchar_p),
    ("release_number", ctypes.c_ushort),
    ("manufacturer_string", ctypes.c_wchar_p),
    ("product_string", ctypes.c_wchar_p),
    ("usage_page", ctypes.c_ushort),
    ("usage", ctypes.c_ushort),
    ("interface_number", ctypes.c_int),
    ("next", ctypes.POINTER(Info13)),
]


class Info14(ctypes.Structure):
    pass


Info14._fields_ = [
    ("path", ctypes.c_char_p),
    ("vendor_id", ctypes.c_ushort),
    ("product_id", ctypes.c_ushort),
    ("serial_number", ctypes.c_wchar_p),
    ("release_number", ctypes.c_ushort),
    ("manufacturer_string", ctypes.c_wchar_p),
    ("product_string", ctypes.c_wchar_p),
    ("usage_page", ctypes.c_ushort),
    ("usage", ctypes.c_ushort),
    ("interface_number", ctypes.c_int),
    ("bus_type", ctypes.c_int),
    ("next", ctypes.POINTER(Info14)),
]

Info = Info14 if HAS_VERSION else Info13

dll.hid_init.restype = ctypes.c_int
dll.hid_enumerate.restype = ctypes.POINTER(Info)
dll.hid_enumerate.argtypes = [ctypes.c_ushort, ctypes.c_ushort]
dll.hid_open_path.restype = ctypes.c_void_p
dll.hid_open_path.argtypes = [ctypes.c_char_p]
dll.hid_read_timeout.restype = ctypes.c_int
dll.hid_read_timeout.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_int,
]

SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
OUT = sys.argv[2] if len(sys.argv) > 2 else "hidcap.log"

dll.hid_init()
print(f"hidapi {'>=0.14' if HAS_VERSION else '0.13'} struct layout, VID 0x2D40")

devs = []
cur = dll.hid_enumerate(0x2D40, 0)
while cur:
    d = cur.contents
    devs.append((d.interface_number, d.usage_page, d.usage, d.path, d.product_string))
    cur = d.next

for iface, up, u, path, prod in devs:
    print(f"  iface={iface} usage_page={up:#x} usage={u:#x} prod={prod!r}")

stop = threading.Event()
loglock = threading.Lock()
log = open(OUT, "w", encoding="utf-8")
log.write(f"# {time.strftime('%Y-%m-%dT%H:%M:%S')} secs={SECS}\n")
stats = {}


def reader(iface, path):
    dev = dll.hid_open_path(path)
    if not dev:
        print(f"iface={iface}: OPEN FAILED")
        return
    print(f"iface={iface}: open ok")
    buf = ctypes.create_string_buffer(4096)
    t0 = time.time()
    counts = collections.Counter()
    prev = None
    n = 0
    lens = collections.Counter()
    while not stop.is_set():
        r = dll.hid_read_timeout(dev, buf, 4096, 100)
        if r <= 0:
            continue
        n += 1
        data = buf.raw[:r]
        lens[r] += 1
        if prev is not None and len(prev) == len(data):
            for i, (a, b) in enumerate(zip(prev, data)):
                if a != b:
                    counts[i] += 1
        prev = data
        with loglock:
            log.write(f"{time.time() - t0:9.4f}\t{iface}\t{r}\t{data.hex()}\n")
    stats[iface] = (n, lens, counts)


threads = [
    threading.Thread(target=reader, args=(i, p), daemon=True) for i, _, _, p, _ in devs
]
for t in threads:
    t.start()
try:
    time.sleep(SECS)
finally:
    stop.set()
    for t in threads:
        t.join(timeout=2)
    log.close()

print(f"\nwrote {OUT}")
for iface, (n, lens, counts) in sorted(stats.items()):
    print(f"iface={iface}: {n} reports, lens={dict(lens)}")
    print(f"  top changing byte offsets: {counts.most_common(24)}")
