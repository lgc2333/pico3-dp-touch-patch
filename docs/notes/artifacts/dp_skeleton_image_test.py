#!/usr/bin/env python3
"""End-to-end check of an *actually patched* driver_pico.dll.

Maps the image exactly as the loader would (all PE sections, including the
injected `.pitouch`), then:

  * checks that the two hooked call sites jump into the payload's stubs;
  * calls the driver's input-update entry point (`sub_180019580`) with a fake
    controller and key report and checks that the injected code hands two
    31-bone skeletons (motion range 0 and 1) to `UpdateSkeletonComponent`.

Produce the input with an unelevated copy of the patch script:

    cp driver_pico.dll.orig temp/driver_port/patch_test/driver_pico.dll
    powershell -File src/windows/src/patch_driver.ps1 -Dll <that copy>

    uv run --with capstone --with keystone-engine --with pefile --with unicorn \\
        python docs/notes/artifacts/dp_skeleton_image_test.py [patched.dll]
"""

import argparse
import json
import struct
import sys
from pathlib import Path

import pefile
import unicorn
from unicorn import UC_ARCH_X86, UC_HOOK_CODE, UC_MODE_64, Uc
from unicorn.x86_const import (
    UC_X86_REG_R8,
    UC_X86_REG_R9,
    UC_X86_REG_RCX,
    UC_X86_REG_RDX,
    UC_X86_REG_RSP,
)

REPO = Path(__file__).resolve().parents[3]
import build_dp_skeleton_payload as B

FAKE = 0x5000000
FAKE_IFACE = FAKE + 0x1000
FAKE_VTABLE = FAKE + 0x2000
STUB_UPDATE_SKEL = FAKE + 0x3000
CTRL = 0x6000000
KEY6 = 0x6001000
STACK = 0x7000000
STACK_TOP = STACK + 0x100000
SENTINEL = FAKE + 0x4000
STOP = B.DP_UPDATE_HOOK_NEXT  # the stub jumps back into the driver here
UPDATE_SITE = B.DP_UPDATE_HOOK_SITE
CREATE_SITE = B.DP_CREATE_HOOK_SITE


def align_up(x, a=0x1000):
    return (x + a - 1) // a * a


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--dll",
        default=str(REPO / "temp/driver_port/patch_test/driver_pico.dll"),
        help="a driver_pico.dll that patch_driver.ps1 already patched",
    )
    ap.add_argument(
        "--manifest",
        default=str(REPO / "src/windows/src/driver_patch/dp_skeleton_payload.json"),
    )
    a = ap.parse_args()
    man = json.loads(Path(a.manifest).read_text(encoding="utf-8"))

    pe = pefile.PE(a.dll)
    names = [s.Name.rstrip(b"\0").decode() for s in pe.sections]
    if ".pitouch" not in names:
        return f"{a.dll} has no .pitouch section - not patched?"
    print(
        f"image: {pe.FILE_HEADER.NumberOfSections} sections, SizeOfImage "
        f"{pe.OPTIONAL_HEADER.SizeOfImage:#x}, patched entry in the section table"
    )

    uc = Uc(UC_ARCH_X86, UC_MODE_64)
    for s in pe.sections:
        va = B.DP_BASE + s.VirtualAddress
        uc.mem_map(
            va, align_up(max(s.Misc_VirtualSize, s.SizeOfRawData)), unicorn.UC_PROT_ALL
        )
        uc.mem_write(va, s.get_data())
    uc.mem_map(STACK, 0x100000, unicorn.UC_PROT_ALL)
    uc.mem_map(FAKE, 0x10000, unicorn.UC_PROT_ALL)
    uc.mem_map(CTRL, 0x20000, unicorn.UC_PROT_ALL)

    for site, kind in ((CREATE_SITE, "create"), (UPDATE_SITE, "update")):
        raw = uc.mem_read(site, 5)
        if raw[0] not in (0xE8, 0xE9):
            return f"hook site {site:#x} does not hold a call/jmp"
        target = site + 5 + struct.unpack("<i", raw[1:5])[0]
        want = int(man["stubs"][kind], 16)
        if target != want:
            return f"hook {kind} points at {target:#x}, expected {want:#x}"
        print(f"hook {kind}: {site:#x} -> {target:#x}")

    calls = []
    uc.mem_write(STUB_UPDATE_SKEL, b"\x31\xc0\xc3")  # EVRInputError_None
    uc.mem_write(
        FAKE_VTABLE, struct.pack("<QQQQQQQQ", 0, 0, 0, 0, 0, 0, STUB_UPDATE_SKEL, 0)
    )
    uc.mem_write(FAKE_IFACE, struct.pack("<Q", FAKE_VTABLE))
    uc.mem_write(B.DP_IVRINPUT_GLOBAL, struct.pack("<Q", FAKE_IFACE))

    def hook(uc, address, size, user):
        if address == STUB_UPDATE_SKEL:
            r9 = uc.reg_read(UC_X86_REG_R9)
            rsp = uc.reg_read(UC_X86_REG_RSP)
            count = struct.unpack("<Q", uc.mem_read(rsp + 0x28, 8))[0]
            calls.append(
                (
                    uc.reg_read(UC_X86_REG_RDX),
                    uc.reg_read(UC_X86_REG_R8),
                    uc.mem_read(r9, count * 32),
                )
            )
        elif address == STOP:
            uc.emu_stop()

    uc.hook_add(UC_HOOK_CODE, hook)

    uc.mem_write(CTRL + 8, struct.pack("<I", 1))  # right hand
    uc.mem_write(CTRL + 0x130, struct.pack("<I", 7))
    uc.mem_write(CTRL + 0x138, struct.pack("<Q", 0x1234))  # property container
    uc.mem_write(KEY6, struct.pack("<HBBBB", 0x20 | 0x80, 0, 0, 200, 100))
    state = int(man["symbols"]["STATE"], 16)
    uc.mem_write(state + 8, struct.pack("<Q", 0xDEADBEEF))  # as if the create hook ran

    rsp = STACK_TOP - 0x8008
    uc.mem_write(rsp, struct.pack("<Q", SENTINEL))
    uc.reg_write(UC_X86_REG_RSP, rsp)
    uc.reg_write(UC_X86_REG_RCX, CTRL)
    uc.reg_write(UC_X86_REG_RDX, KEY6)
    uc.emu_start(UPDATE_SITE, SENTINEL, count=200_000_000)

    print("skeleton updates:", [(hex(h), r, len(t) // 32) for h, r, t in calls])
    if len(calls) != 2 or any(
        h != 0xDEADBEEF or len(t) != 31 * 32 for h, _r, t in calls
    ):
        return "the patched image did not drive the skeleton"
    if [r for _h, r, _t in calls] != [0, 1]:
        return "motion ranges are not 0 and 1"
    print("OK: the patched image drives the skeleton through the hook")
    return None


if __name__ == "__main__":
    problem = main()
    if problem:
        print(f"FAILED: {problem}")
        sys.exit(1)
