#!/usr/bin/env python3
"""Read the hand skeleton the way an *application* sees it.

Connects to the running SteamVR as a background app, binds a skeleton action for
`/skeleton/hand/{left,right}` (manifest + bindings in `probe_actions/`), then
polls what the runtime hands out: action active?, tracking level, the finger-curl
summary, and the 31 bone transforms.

    uv run --with openvr python docs/notes/artifacts/app_skeleton_probe.py [seconds]

A fist pulls every fingertip in towards the wrist (~60-90 mm); a straight hand
puts them at ~150-170 mm.  Prints a line per hand per sample.
"""

import math
import struct
import sys
import time
from pathlib import Path

import openvr

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "probe_actions" / "actions.json"

FINGERS = {
    "thumb": [2, 3, 4, 5],
    "index": [6, 7, 8, 9, 10],
    "middle": [11, 12, 13, 14, 15],
    "ring": [16, 17, 18, 19, 20],
    "pinky": [21, 22, 23, 24, 25],
}
PARENT = {
    0: None, 1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 1, 7: 6, 8: 7, 9: 8, 10: 9,
    11: 1, 12: 11, 13: 12, 14: 13, 15: 14, 16: 1, 17: 16, 18: 17, 19: 18,
    20: 19, 21: 1, 22: 21, 23: 22, 24: 23, 25: 24, 26: 1, 27: 26, 28: 26,
    29: 26, 30: 26,
}


def quat_mat(q):
    x, y, z, w = q
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]


def mat_vec(a, v):
    return [sum(a[i][k] * v[k] for k in range(3)) for i in range(3)]


def world(bones):
    pos, rot = [None] * 31, [None] * 31
    for b in range(31):
        tr = bones[b]
        p = [tr.position.v[0], tr.position.v[1], tr.position.v[2]]
        r = quat_mat(
            [
                tr.orientation.x,
                tr.orientation.y,
                tr.orientation.z,
                tr.orientation.w,
            ]
        )
        par = PARENT[b]
        if par is None:
            pos[b], rot[b] = p, r
        else:
            t = mat_vec(rot[par], p)
            pos[b] = [pos[par][i] + t[i] for i in range(3)]
            rot[b] = [
                [sum(rot[par][i][k] * r[k][j] for k in range(3)) for j in range(3)]
                for i in range(3)
            ]
    return pos


def describe(pos):
    tips = " ".join(
        f"{n[:3]}={math.dist(pos[c[-1]], pos[1]) * 1000:4.0f}"
        for n, c in FINGERS.items()
    )
    return f"tip->wrist(mm) {tips}"


def model_space(bones):
    """Model space needs no composition: bone positions are already absolute."""
    return [
        [b.position.v[0], b.position.v[1], b.position.v[2]] for b in bones
    ]


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    # A background app gets no input at all (every action reads inactive), so the
    # skeleton can only be measured as a scene app -- that needs the game closed.
    app_type = (
        openvr.VRApplication_Scene
        if "--scene" in sys.argv
        else openvr.VRApplication_Background
    )
    print("app type:", "Scene" if app_type == openvr.VRApplication_Scene else "Background")
    openvr.init(app_type)
    iv = openvr.VRInput()
    iv.setActionManifestPath(str(MANIFEST))
    aset = iv.getActionSetHandle("/actions/probe")
    actions = {
        "left": iv.getActionHandle("/actions/probe/in/skeleton_left"),
        "right": iv.getActionHandle("/actions/probe/in/skeleton_right"),
    }
    controls = {
        "left": (
            iv.getActionHandle("/actions/probe/in/trigger_left"),
            iv.getActionHandle("/actions/probe/in/trigger_value_left"),
        ),
        "right": (
            iv.getActionHandle("/actions/probe/in/trigger_right"),
            iv.getActionHandle("/actions/probe/in/trigger_value_right"),
        ),
    }
    sets = (openvr.VRActiveActionSet_t * 1)()
    sets[0].ulActionSet = aset
    sets[0].ulRestrictedToDevice = openvr.k_ulInvalidInputValueHandle
    sets[0].nPriority = 0
    print(f"action set handle = {aset:#x}  actions = {actions}")

    end = time.time() + seconds
    while time.time() < end:
        iv.updateActionState(sets)
        line = time.strftime("%H:%M:%S")
        for hand in ("left", "right"):
            dact, aact = controls[hand]
            ddat = iv.getDigitalActionData(dact, openvr.k_ulInvalidInputValueHandle)
            adat = iv.getAnalogActionData(aact, openvr.k_ulInvalidInputValueHandle)
            line += (
                f"\n  [{hand}] trigger click: active={bool(ddat.bActive)}"
                f" state={bool(ddat.bState)} | value: active={bool(adat.bActive)}"
                f" x={adat.x:.2f}"
            )
        for hand, action in actions.items():
            data = iv.getSkeletalActionData(action)
            if not data.bActive:
                line += f"  [{hand}] inactive (origin {data.activeOrigin})"
                continue
            level = iv.getSkeletalTrackingLevel(action)
            summ = iv.getSkeletalSummaryData(action, openvr.VRSummaryType_FromDevice)
            curls = " ".join(f"{c:4.2f}" for c in summ.flFingerCurl)
            bones = (openvr.VRBoneTransform_t * 31)()
            iv.getSkeletalBoneData(
                action,
                openvr.VRSkeletalTransformSpace_Parent,
                openvr.VRSkeletalMotionRange_WithController,
                bones,
            )
            pos = world(bones)
            mbones = (openvr.VRBoneTransform_t * 31)()
            for name, rng in (
                ("with", openvr.VRSkeletalMotionRange_WithController),
                ("without", openvr.VRSkeletalMotionRange_WithoutController),
            ):
                iv.getSkeletalBoneData(
                    action,
                    openvr.VRSkeletalTransformSpace_Model,
                    rng,
                    mbones,
                )
                mpos = model_space(mbones)
                line += (
                    f"\n      model[{name}] w={mpos[1][0]:+.3f},{mpos[1][1]:+.3f},"
                    f"{mpos[1][2]:+.3f} tip_index={mpos[10][0]:+.3f},"
                    f"{mpos[10][1]:+.3f},{mpos[10][2]:+.3f} "
                    f"{describe(mpos)}"
                )
            line += (
                f"\n  [{hand}] active level={level} curls=[{curls}] {describe(pos)}"
            )
        print(line, flush=True)
        time.sleep(0.7)

    openvr.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
