#!/usr/bin/env python3
"""Generate the grip-limit pose the patch hands to `CreateSkeletonComponent`.

`pGripLimitTransforms` is the driver-side way to tell the runtime what the
hand's *fully gripping* pose looks like; passing NULL makes the runtime use its
own default fist (Valve's, i.e. a different bone convention than PICO's tables).
This writes the pose our own data uses, straight out of v2's generator:

    uv run --with capstone --with keystone-engine --with pefile --with unicorn \\
        python docs/notes/artifacts/make_grip_limit_pose.py [mask] [trigger] [grip]

Default is "grip fully pressed" (mask 0, grip 1.0) -- the tightest pose the v2
tables produce.  Output: `src/windows/src/driver_patch/grip_limit_pose.bin`
(31 x VRBoneTransform_t = 992 bytes, same layout the driver sends).
"""

import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE))

import dp_skeleton_payload_test as T
from unicorn.x86_const import UC_X86_REG_XMM2, UC_X86_REG_XMM3

V2 = str(REPO / "temp/v2/app/openvr_driver/bin/win64/driver_pico.dll")
OUT = REPO / "src/windows/src/driver_patch/grip_limit_pose.bin"


def main():
    mask = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x0000
    trig = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    grip = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    run = T.Run(False, V2)
    run.prepare_globals()
    run.uc.mem_map(T.SCRATCH_A, 0x20000, 1 | 2 | 4)
    run.uc.mem_write(T.SCRATCH_A, b"\0" * 0x300)
    for _ in range(60):  # reach the steady state (the updater latches on a timer)
        run.calls.clear()
        run.call(
            T.updater_entry(False),
            [T.SCRATCH_A, mask],
            floats=((UC_X86_REG_XMM2, trig), (UC_X86_REG_XMM3, grip)),
        )
    raw = run.calls[0][3]
    if len(raw) != 31 * 32:
        raise SystemExit(f"unexpected transform size {len(raw)}")
    OUT.write_bytes(raw)
    fl = struct.unpack("<248f", raw)
    print(f"mask={mask:#06x} trigger={trig} grip={grip} -> {OUT} ({len(raw)} bytes)")
    print("first bone pos/quat:", [round(v, 3) for v in fl[:8]])


if __name__ == "__main__":
    main()
