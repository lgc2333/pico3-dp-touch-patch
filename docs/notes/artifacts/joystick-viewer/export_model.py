"""Export the controller meshes plus the measured pad frame as `web/model.js`.

Usage:
  uv run --with numpy python export_model.py [--driver DIR]

`--driver` is the folder that holds `driver_pico.dll`; the meshes are read from
`<driver>/resources/rendermodels/pico_neo3_leftcontroller`.  The output is
`web/model.js` next to this script, which git ignores.
"""

import argparse
import json
import math
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "web")


def find_driver():
    """Look for the DP driver on every drive, Program Files first."""
    for env in ("ProgramFiles", "ProgramFiles(x86)"):
        root = os.environ.get(env)
        if root:
            yield os.path.join(
                root, "BusinessStreaming", "BusinessStreamingDP", "driver"
            )
    for letter in "CDEFGHIJKLMNOPQRSTUVWXYZ":
        yield os.path.join(
            letter + ":" + os.sep,
            "Program Files",
            "BusinessStreaming",
            "BusinessStreamingDP",
            "driver",
        )


def default_driver():
    for cand in find_driver():
        if os.path.isdir(os.path.join(cand, "resources", "rendermodels")):
            return cand
    return ""


ap = argparse.ArgumentParser(description="export the joystick viewer model")
ap.add_argument("--driver", default=None, help="folder that holds driver_pico.dll")
args = ap.parse_args()
driver = args.driver or default_driver()
if not driver:
    raise SystemExit("[X] driver_pico.dll folder not found; pass --driver")
print(f"[i] driver: {driver}")
BASE = os.path.join(driver, "resources", "rendermodels", "pico_neo3_leftcontroller")

PARTS = {
    "body": "left_body",
    "grip": "left_grip",
    "stick": "left_joystick",
    "x": "left_x_button",
    "y": "left_y_button",
    "app": "left_app_button",
    "home": "left_home_button",
}


def load(name):
    vs, fs = [], []
    with open(os.path.join(BASE, name), encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("v "):
                p = line.split()
                vs.append((float(p[1]), float(p[2]), float(p[3])))
            elif line.startswith("f "):
                idx = [int(t.split("/")[0]) - 1 for t in line.split()[1:]]
                for k in range(1, len(idx) - 1):
                    fs.append((idx[0], idx[k], idx[k + 1]))
    return np.array(vs) * 1000.0, np.array(fs, dtype=np.int32)


def pca_thin_axis(P):
    c = P.mean(axis=0)
    _w, v = np.linalg.eigh((P - c).T @ (P - c) / len(P))
    n = v[:, 0]
    return n if n[2] > 0 else -n


GRIP_Z = (62.0, 134.0)  # the handle, between the pad and the tail
SPIN_DEG = 1.37  # extra turn about the stick axis; user-chosen, see the frame block


def handle_mid(V):
    """Midpoint of the handle centreline.

    Slabs along z give one bounding-box centre each; the line through those
    centres is the handle axis, and its midpoint is where the palm sits.
    """
    zs, cs = [], []
    for z0 in np.arange(GRIP_Z[0], GRIP_Z[1], 2.0):
        m = (V[:, 2] >= z0) & (V[:, 2] < z0 + 2.0)
        if m.sum() < 20:
            continue
        B = V[m]
        zs.append(z0 + 1.0)
        cs.append(
            (
                0.5 * (B[:, 0].min() + B[:, 0].max()),
                0.5 * (B[:, 1].min() + B[:, 1].max()),
            )
        )
    A = np.column_stack([np.array(zs), np.ones(len(zs))])
    kx, bx = np.linalg.lstsq(A, np.array(cs)[:, 0], rcond=None)[0]
    ky, by = np.linalg.lstsq(A, np.array(cs)[:, 1], rcond=None)[0]
    zm = 0.5 * (GRIP_Z[0] + GRIP_Z[1])
    return np.array([kx * zm + bx, ky * zm + by, zm])


def vec(a):
    return [round(float(x), 6) for x in a]


# --- pad plane: one thin-axis normal per cap; four caps must agree ----------
cap_n = {}
for key in ("x", "y", "app", "home"):
    V, _ = load(f"{PARTS[key]}.obj.orig")
    cap_n[key] = pca_thin_axis(V)
n = np.mean(list(cap_n.values()), axis=0)
n /= np.linalg.norm(n)
caps = {k: load(f"{PARTS[k]}.obj.orig")[0].mean(axis=0) for k in cap_n}

# --- stick: direction fixed = pad normal, fit only the axis position -------
Vj, _ = load("left_joystick.obj.orig")
e1 = np.cross(n, [0, 0, 1.0])
e1 /= np.linalg.norm(e1)
e2 = np.cross(n, e1)
best = None
for du in np.arange(-2, 2.001, 0.05):
    for dv in np.arange(-2, 2.001, 0.05):
        p0 = Vj.mean(axis=0) + du * e1 + dv * e2
        t = (Vj - p0) @ n
        r = np.linalg.norm((Vj - p0) - t[:, None] * n, axis=1)
        s, w = 0.0, 0
        for lo in np.arange(t.min(), t.max(), 0.5):
            m = (t >= lo) & (t < lo + 0.5)
            if m.sum() >= 6:
                s += r[m].std() * m.sum()
                w += m.sum()
        s /= max(w, 1)
        if best is None or s < best[0]:
            best = (s, p0)
axis_c = best[1]
t = (Vj - axis_c) @ n
r = np.linalg.norm((Vj - axis_c) - t[:, None] * n, axis=1)

# Which end of the stick points away from the pad?  The thumb cap is a closed
# disc, so it has vertices near the axis; the buried end is an open ring.
lo_rmin = float(r[t < t.min() + 0.6].min())
hi_rmin = float(r[t > t.max() - 0.6].min())
if lo_rmin < hi_rmin:
    n = -n  # the closed disc sits at the low end, so the pad faces the other way
t = (Vj - axis_c) @ n
r = np.linalg.norm((Vj - axis_c) - t[:, None] * n, axis=1)
assert float(r[t > t.max() - 0.6].min()) < 1.5, "the cap end must face the pad"

d0 = float(np.mean([c @ n for c in caps.values()]))
spread = max(abs(c @ n - d0) for c in caps.values())
axis_at_plane = axis_c + (d0 - axis_c @ n) * n
cap_t = float(t.max())
foot_t = float(t.min())
cap_r = float(r[np.abs(t - cap_t) < 0.6].max())

# --- pad frame -------------------------------------------------------------
# Both rotation axes lie in the pad plane.  The in-plane up direction is the
# line from the handle midpoint to the system button, projected onto the plane:
# that is what the thumb reads as up, and it does not follow world up.
Vb, _ = load("left_body.obj.orig")
Vh, _ = load(f"{PARTS['home']}.obj.orig")
mid = handle_mid(Vb)
sys_c = Vh.mean(axis=0)
g = sys_c - mid
g_in = g - (g @ n) * n
up = g_in / np.linalg.norm(g_in)
# The user tried the grip-axis projection (2.59 deg) and found it a touch too far,
# then asked for the line above: on its own it reads ~1 deg short.  SPIN_DEG is the
# extra turn about the stick axis that settles the feel.  It is a chosen value.
d_spin = math.radians(SPIN_DEG)
up = math.cos(d_spin) * up + math.sin(d_spin) * np.cross(n, up)
up /= np.linalg.norm(up)
e_h = np.cross(n, up)
right = -e_h
S = np.column_stack(
    [e_h, n, up]
)  # x -> across, y -> outward, z -> grip midpoint to system button, then SPIN_DEG
assert abs(np.linalg.det(S) - 1) < 1e-9
assert abs(float(S[:, 1] @ n) - 1.0) < 1e-12
assert abs(float(up @ n)) < 1e-12
world_up = np.cross(np.cross([0.0, 0.0, 1.0], n), n)  # the frame this one replaces
world_up /= np.linalg.norm(world_up)
spin = math.degrees(math.atan2(float(np.cross(world_up, up) @ n), float(world_up @ up)))
b = math.degrees(math.asin(max(-1.0, min(1.0, -S[2, 0]))))
a = math.degrees(math.atan2(S[2, 1], S[2, 2]))
c = math.degrees(math.atan2(S[1, 0], S[0, 0]))

meshes = {}
for key, name in PARTS.items():
    V, F = load(f"{name}.obj.orig")
    meshes[key] = {
        "pos": [round(float(x), 4) for x in V.reshape(-1)],
        "idx": [int(x) for x in F.reshape(-1)],
    }

frame = {
    "n": vec(n),
    "up": vec(up),
    "right": vec(right),
    "axisX": vec(up),
    "axisY": vec(e_h),
    "planeOffset": round(d0, 4),
    "axisAtPlane": vec(axis_at_plane),
    "axisEnd": vec(axis_c),
    "capT": round(cap_t, 4),
    "footT": round(foot_t, 4),
    "capRadius": round(cap_r, 4),
    "capSpread": round(float(spread), 4),
    "protrusion": round(cap_t - (d0 - axis_c @ n), 4),
    "buried": round((d0 - axis_c @ n) - foot_t, 4),
    "rotateXyz": [round(b, 3), round(a, 3), round(c, 3)],
    "S": [vec(S[:, i]) for i in range(3)],
    "pressTranslate": [0.0, -2.5, 0.0],
}

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "model.js"), "w", encoding="utf-8", newline="\n") as f:
    f.write("// generated by temp/joyaxis/export_model.py -- do not edit\n")
    f.write("export const FRAME = " + json.dumps(frame, indent=1) + ";\n")
    f.write("export const MESHES = {\n")
    for k, m in meshes.items():
        f.write(
            f' "{k}": {{ pos: {json.dumps(m["pos"])}, idx: {json.dumps(m["idx"])} }},\n'
        )
    f.write("};\n")

print(
    f"pad normal (out) = ({n[0]:+.5f},{n[1]:+.5f},{n[2]:+.5f})  tilt {math.degrees(math.acos(abs(n[2]))):.2f}deg"
)
print(f"  closed-disc end radii: low {lo_rmin:.2f} / high {hi_rmin:.2f}")
print(
    f"cap spacing from the plane: protrusion {cap_t - (d0 - axis_c @ n):.2f} mm, buried {(d0 - axis_c @ n) - foot_t:.2f} mm"
)
print(f"cap radius {cap_r:.2f} mm   cap plane spread {spread:.3f} mm")
print(f"stick axis point = ({axis_c[0]:+.3f},{axis_c[1]:+.3f},{axis_c[2]:+.3f})")
print(
    f"grip mid = ({mid[0]:+.2f},{mid[1]:+.2f},{mid[2]:+.2f}) mm"
    f"   system button centre = ({sys_c[0]:+.2f},{sys_c[1]:+.2f},{sys_c[2]:+.2f}) mm"
)
print(
    f"grip mid -> system button = {np.linalg.norm(g):.2f} mm,"
    f" {math.degrees(math.acos(abs(float(g / np.linalg.norm(g) @ n)))):.2f} deg off the pad normal,"
    f" {np.linalg.norm(g_in):.2f} mm of it inside the plane"
)
print(
    f"X-input axis = ({up[0]:+.4f},{up[1]:+.4f},{up[2]:+.4f})  {math.degrees(math.acos(abs(up[2]))):.2f} deg from vertical"
    f"  ({spin:+.2f} deg spin about the stick axis)"
)
print(f"Y-input axis = ({e_h[0]:+.4f},{e_h[1]:+.4f},{e_h[2]:+.4f})")
print(f"rotate_xyz   = [{b:.3f}, {a:.3f}, {c:.3f}] deg")
print(
    f"press (0,-2.5,0) in the S frame -> {vec(-2.5 * S[:, 1])} mm  (dot with out-normal {float(-2.5 * S[:, 1] @ n):+.2f})"
)
print(
    f"wrote {os.path.join(OUT, 'model.js')} ({os.path.getsize(os.path.join(OUT, 'model.js')) // 1024} KiB)"
)
