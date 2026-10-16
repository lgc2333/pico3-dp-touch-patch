#!/usr/bin/env python3
"""Verify the DP skeleton payload (`src/windows/src/driver_patch/dp_skeleton_payload.bin`).

Two passes:

1. static - every instruction of the relocated cluster must be byte-identical to
   v2's original except the branch displacements / RIP displacements that the
   relocation rewrites, and each rewritten field must point at the mapped target.
2. dynamic - run v2's original skeleton updater and our relocated copy under
   Unicorn with identical inputs and compare the 31 bone transforms they hand to
   `IVRDriverInput::UpdateSkeletonComponent`; also check our `acosf` against the
   correctly rounded float32 result, and the DP key word -> v2 mask translation
   performed by the update stub.

    uv run --with capstone --with keystone-engine --with pefile --with unicorn \\
        python docs/notes/artifacts/dp_skeleton_payload_test.py [--no-dynamic]
"""

import argparse
import json
import math
import random
import struct
import sys
from pathlib import Path

import capstone
import keystone
import pefile
import unicorn
from unicorn import UC_ARCH_X86, UC_HOOK_CODE, UC_MODE_64, Uc
from unicorn.x86_const import (
    UC_X86_REG_R8,
    UC_X86_REG_R9,
    UC_X86_REG_RBX,
    UC_X86_REG_RCX,
    UC_X86_REG_RDX,
    UC_X86_REG_RIP,
    UC_X86_REG_RSP,
    UC_X86_REG_XMM0,
    UC_X86_REG_XMM2,
    UC_X86_REG_XMM3,
)

REPO = Path(__file__).resolve().parents[3]
import build_dp_skeleton_payload as B

STACK = 0x2000000
STACK_TOP = STACK + 0x100000
SCRATCH_A = 0x4000000
SCRATCH_B = 0x4010000
FAKE = 0x5000000
FAKE_IFACE = FAKE + 0x1000
FAKE_VTABLE = FAKE + 0x2000
STUB_UPDATE_SKEL = FAKE + 0x3000
STUB_CREATE_SKEL = FAKE + 0x3100
SENTINEL = FAKE + 0x4000
CTRL = 0x6000000
KEY6 = 0x6001000

man = None
payload = None


def align_up(x, a=0x1000):
    return (x + a - 1) // a * a


# --------------------------------------------------------------- static pass


def static_check(v2_path):
    img = B.Image(v2_path)
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True
    blob, branches, riprefs = B.scan_cluster(img, md)
    assert len(payload) >= len(blob)

    branch_at = {va: (size, target) for va, size, target in branches}
    rip_at = {
        va: (size, disp_off, target) for va, size, disp_off, target, _a, _l in riprefs
    }
    const_span = {
        int(k, 16): (int(v[0], 16), v[1]) for k, v in man["const_span"].items()
    }
    stubs = {k: int(v, 16) for k, v in man["stubs"].items()}

    def map_target(target):
        if B.SRC_START <= target < B.SRC_END:
            return B.SECTION_BASE + (target - B.SRC_START)
        if target in B.SYMBOLS:
            kind, dest = B.SYMBOLS[target]
            if kind == "blob":
                return B.SECTION_BASE + (dest - B.SRC_START)
            if kind == "acosf":
                return stubs["acosf"]
            return dest
        for lo, (new_lo, size) in const_span.items():
            if lo <= target < lo + size:
                return new_lo + (target - lo)
        raise SystemExit(f"cannot map {hex(target)}")

    bad = 0
    va = B.SRC_START
    while va < B.SRC_END:
        ins = next(md.disasm(img.raw[img.off(va) : img.off(va) + 15], va), None)
        assert ins is not None
        orig = bytearray(img.read(va, ins.size))
        new = bytearray(payload[va - B.SRC_START : va - B.SRC_START + ins.size])
        if va in branch_at:
            struct.pack_into("<i", orig, ins.size - 4, 0)
            struct.pack_into("<i", new, ins.size - 4, 0)
        if va in rip_at:
            struct.pack_into("<i", orig, rip_at[va][1], 0)
            struct.pack_into("<i", new, rip_at[va][1], 0)
        if bytes(orig) != bytes(new):
            print(f"byte mismatch at {hex(va)}: {orig.hex()} vs {new.hex()}")
            bad += 1
        if va in branch_at:
            size, target = branch_at[va]
            rel = struct.unpack_from("<i", payload, va - B.SRC_START + size - 4)[0]
            if B.SECTION_BASE + (va - B.SRC_START) + size + rel != map_target(target):
                print(f"branch at {hex(va)} points at the wrong target")
                bad += 1
        if va in rip_at:
            _size, disp_off, target = rip_at[va]
            disp = struct.unpack_from("<i", payload, va - B.SRC_START + disp_off)[0]
            if B.SECTION_BASE + (va - B.SRC_START) + ins.size + disp != map_target(
                target
            ):
                print(f"rip ref at {hex(va)} points at the wrong target")
                bad += 1
        va += ins.size
    print(
        f"static: {len(branches)} branches + {len(riprefs)} rip refs relocated, {bad} mismatch(es)"
    )
    return bad == 0


# -------------------------------------------------------------- dynamic pass


class Run:
    """Map either v2's own image, or just what the payload needs (v2's sections
    would clash with the payload's section RVA)."""

    def __init__(self, payload_mode, v2_path):
        self.uc = Uc(UC_ARCH_X86, UC_MODE_64)
        self.payload_mode = payload_mode
        self.hook_own_acosf = True
        self.calls = []
        if payload_mode:
            self.uc.mem_map(B.SECTION_BASE, align_up(len(payload)), unicorn.UC_PROT_ALL)
            self.uc.mem_write(B.SECTION_BASE, payload)
            self.uc.mem_map(B.DP_BASE + 0x9A000, 0xA000, unicorn.UC_PROT_ALL)
            self.uc.mem_write(
                B.DP_BASE + 0x9A088, struct.pack("<Q", 0x00002B992DDFA232)
            )
            for page, targets in (
                (0x19000, []),
                (0x25000, []),
                (0x46000, [B.DP_BASE + 0x469B0]),
                (0x70000, [B.DP_BASE + 0x70E70, B.DP_BASE + 0x70900]),
            ):
                self.uc.mem_map(B.DP_BASE + page, 0x1000, unicorn.UC_PROT_ALL)
                for t in targets:
                    self.uc.mem_write(t, b"\xc3")
        else:
            pe = pefile.PE(v2_path, fast_load=True)
            for s in pe.sections:
                va = pe.OPTIONAL_HEADER.ImageBase + s.VirtualAddress
                self.uc.mem_map(
                    va,
                    align_up(max(s.Misc_VirtualSize, s.SizeOfRawData)),
                    unicorn.UC_PROT_ALL,
                )
                self.uc.mem_write(va, s.get_data())
        self.uc.mem_map(STACK, 0x100000, unicorn.UC_PROT_ALL)
        self.uc.mem_map(FAKE, 0x10000, unicorn.UC_PROT_ALL)
        self.uc.mem_write(STUB_UPDATE_SKEL, b"\x31\xc0\xc3")  # xor eax,eax / ret
        self.uc.mem_write(STUB_CREATE_SKEL, b"\x31\xc0\xc3")
        self.uc.mem_write(SENTINEL, b"\xf4")
        self.uc.mem_write(
            FAKE_VTABLE,
            struct.pack(
                "<QQQQQQQQ", 0, 0, 0, 0, 0, STUB_CREATE_SKEL, STUB_UPDATE_SKEL, 0
            ),
        )
        self.uc.mem_write(FAKE_IFACE, struct.pack("<Q", FAKE_VTABLE))
        self.uc.hook_add(UC_HOOK_CODE, self.hook)

    def prepare_globals(self):
        if self.payload_mode:
            self.uc.mem_write(B.DP_IVRINPUT_GLOBAL, struct.pack("<Q", FAKE_IFACE))
            self.uc.mem_write(B.DP_DRVCTX_GLOBAL, struct.pack("<Q", 0))
        else:
            self.uc.mem_write(B.DP_BASE + 0x9BD10, struct.pack("<Q", FAKE_IFACE))

    def _emulate_call(self, uc, value):
        rsp = uc.reg_read(UC_X86_REG_RSP)
        ret = struct.unpack("<Q", uc.mem_read(rsp, 8))[0]
        uc.reg_write(UC_X86_REG_RSP, rsp + 8)
        uc.reg_write(UC_X86_REG_RIP, ret)

    def hook(self, uc, address, size, user):
        if address == STUB_UPDATE_SKEL:
            r9 = uc.reg_read(UC_X86_REG_R9)
            rsp = uc.reg_read(UC_X86_REG_RSP)
            count = struct.unpack("<Q", uc.mem_read(rsp + 0x28, 8))[0]
            self.calls.append(
                (
                    "update",
                    uc.reg_read(UC_X86_REG_RDX),
                    uc.reg_read(UC_X86_REG_R8),
                    uc.mem_read(r9, min(count, 31) * 32),
                )
            )
            return
        if address == STUB_CREATE_SKEL:
            rsp = uc.reg_read(UC_X86_REG_RSP)
            stack = [
                struct.unpack("<Q", uc.mem_read(rsp + 0x28 + i * 8, 8))[0]
                for i in range(5)
            ]
            self.calls.append(
                (
                    "create",
                    uc.reg_read(UC_X86_REG_RDX),
                    uc.reg_read(UC_X86_REG_R8),
                    uc.reg_read(UC_X86_REG_R9),
                    stack,
                )
            )
            return
        if address == SENTINEL:
            uc.emu_stop()
            return
        if self.payload_mode and address == B.DP_UPDATE_HOOK_NEXT:
            # the DP input-update body is not part of this harness: stop here
            uc.emu_stop()
            return
        if not self.payload_mode:
            funcs = {
                B.DP_BASE + 0x72B16: ("sinf", 4),
                B.DP_BASE + 0x72B3A: ("acosf", 4),
                B.DP_BASE + 0x72B40: ("sin", 8),
            }
        else:
            funcs = {
                B.DP_BASE + 0x70E70: ("sinf", 4),
                B.DP_BASE + 0x70900: ("sin", 8),
            }
            if self.hook_own_acosf:
                funcs[int(man["stubs"]["acosf"], 16)] = ("acosf", 4)
        name_size = funcs.get(address)
        if name_size:
            name, size = name_size
            raw = uc.reg_read(UC_X86_REG_XMM0).to_bytes(16, "little")
            x = struct.unpack("<d" if size == 8 else "<f", raw[:size])[0]
            if name in ("sin", "sinf"):
                y = math.sin(x)
            else:
                y = math.acos(max(-1.0, min(1.0, x)))
            uc.reg_write(
                UC_X86_REG_XMM0,
                int.from_bytes(
                    struct.pack("<d" if size == 8 else "<f", y) + b"\0" * 16, "little"
                ),
            )
            self._emulate_call(uc, y)
            return
        if self.payload_mode and address == B.DP_BASE + 0x469B0:  # DP cookie check
            cookie = struct.unpack("<Q", uc.mem_read(B.DP_BASE + 0x9A088, 8))[0]
            if uc.reg_read(UC_X86_REG_RCX) != cookie:
                raise SystemExit("stack cookie mismatch in the relocated updater")
            self._emulate_call(uc, None)
            return
        if self.payload_mode and address == B.DP_BASE + 0x25110:  # driver log
            self._emulate_call(uc, None)

    def call(self, fn, args, floats=(), rsp_top=STACK_TOP):
        uc = self.uc
        rsp = rsp_top - 0x8008  # headroom above, (rsp % 16) == 8
        uc.mem_write(rsp, struct.pack("<Q", SENTINEL))
        for i, reg in enumerate(
            (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8, UC_X86_REG_R9)
        ):
            if i < len(args):
                uc.reg_write(reg, args[i])
        for reg, value in floats:
            uc.reg_write(
                reg, int.from_bytes(struct.pack("<f", value) + b"\0" * 12, "little")
            )
        uc.reg_write(UC_X86_REG_RSP, rsp)
        uc.emu_start(fn, SENTINEL, count=200_000_000)


def updater_entry(payload_mode):
    if payload_mode:
        return B.SECTION_BASE + (B.UPDATER_SRC - B.SRC_START)
    return B.UPDATER_SRC


def run_updater(v2_path, payload_mode, scratch, mask, trigger, grip, hook_acosf=True):
    r = Run(payload_mode, v2_path)
    r.hook_own_acosf = hook_acosf
    r.prepare_globals()
    r.uc.mem_map(SCRATCH_A, 0x20000, unicorn.UC_PROT_ALL)
    r.uc.mem_write(scratch, b"\0" * 0x300)
    r.call(
        updater_entry(payload_mode),
        [scratch, mask],
        floats=((UC_X86_REG_XMM2, trigger), (UC_X86_REG_XMM3, grip)),
    )
    return r.calls


def dynamic_check(v2_path):
    random.seed(1234)
    cases = [
        (0, 0.0, 0.0),
        (0x2, 0.0, 0.0),
        (0x8, 0.0, 0.0),
        (0x2 | 0x8, 0.0, 0.0),
        (0x2, 1.0, 0.0),
        (0x8, 0.0, 1.0),
        (0x1 | 0x4, 0.5, 0.5),
        (0x20 | 0x80, 0.25, 0.75),
        (0x202A & 0xFFFF, 1.0, 1.0),
        (0x40 | 0x2 | 0x8, 0.9, 0.1),
    ]
    for _ in range(20):
        cases.append((random.getrandbits(16), random.random(), random.random()))

    for mask, trig, grip in cases:
        a = run_updater(v2_path, False, SCRATCH_A, mask, trig, grip)
        b = run_updater(v2_path, True, SCRATCH_B, mask, trig, grip)
        if len(a) != 2 or len(b) != 2:
            print(f"mask={mask:04x}: call count {len(a)} vs {len(b)}")
            return False
        for i, (ca, cb) in enumerate(zip(a, b)):
            if ca[:3] != cb[:3] or ca[3] != cb[3]:
                print(f"mask={mask:04x} call {i}: relocated updater differs from v2")
                return False
    print(f"dynamic: relocated updater matches v2 bit for bit on {len(cases)} cases")

    worst, worst_case = 0, None
    for mask, trig, grip in cases:
        a = run_updater(v2_path, False, SCRATCH_A, mask, trig, grip)
        b = run_updater(v2_path, True, SCRATCH_B, mask, trig, grip, hook_acosf=False)
        for ca, cb in zip(a, b):
            fa = struct.unpack(f"<{len(ca[3]) // 4}f", ca[3])
            fb = struct.unpack(f"<{len(cb[3]) // 4}f", cb[3])
            d = max(abs(x - y) for x, y in zip(fa, fb))
            if d > worst:
                worst, worst_case = d, (mask, trig, grip)
    print(f"dynamic: our acosf max bone delta vs v2 = {worst:.1e} (worst {worst_case})")

    # our acosf against the correctly rounded float32 result
    r = Run(True, v2_path)
    r.hook_own_acosf = False
    r.prepare_globals()
    acosf = int(man["stubs"]["acosf"], 16)
    worst_ulp = 0
    values = [0.0, 1.0, -1.0, 0.5, -0.5, 0.99999994, -0.99999994, 0.99999, -0.999]
    random.seed(7)
    values += [random.uniform(-1, 1) for _ in range(200)]
    values += [
        random.choice([1.0, -1.0]) * (1 - random.random() * 1e-5) for _ in range(100)
    ]
    for v in values:
        x32 = struct.unpack("<f", struct.pack("<f", v))[0]
        r.call(acosf, [], floats=((UC_X86_REG_XMM0, x32),))
        got = struct.unpack(
            "<f", r.uc.reg_read(UC_X86_REG_XMM0).to_bytes(16, "little")[:4]
        )[0]
        want = struct.unpack("<f", struct.pack("<f", math.acos(x32)))[0]
        worst_ulp = max(
            worst_ulp,
            abs(
                struct.unpack("<i", struct.pack("<f", got))[0]
                - struct.unpack("<i", struct.pack("<f", want))[0]
            ),
        )
    print(f"dynamic: our acosf is within {worst_ulp} ULP of the correct float32 result")

    # stub smoke test: create -> handle -> update drives the skeleton twice
    ks = keystone.Ks(keystone.KS_ARCH_X86, keystone.KS_MODE_64)
    fake_create, _n = ks.asm(
        "mov rax, [rsp+0x48]\n mov rdx, 0xDEADBEEF\n mov [rax], rdx\n xor eax, eax\n ret",
        addr=STUB_CREATE_SKEL,
    )
    r = Run(True, v2_path)
    r.prepare_globals()
    r.uc.mem_write(STUB_CREATE_SKEL, bytes(fake_create))
    r.uc.mem_map(CTRL, 0x20000, unicorn.UC_PROT_ALL)
    r.uc.mem_write(CTRL + 8, struct.pack("<I", 1))
    r.uc.mem_write(CTRL + 0x130, struct.pack("<I", 7))
    r.uc.mem_write(CTRL + 0x138, struct.pack("<Q", 0x1234))
    r.uc.mem_write(KEY6, struct.pack("<HBBBB", 0x20 | 0x80, 0, 0, 128, 255))
    r.uc.mem_write(0x6002000, b"controller %d actived\0")
    r.uc.reg_write(UC_X86_REG_RBX, CTRL)
    r.call(int(man["stubs"]["create"], 16), [0x6002000])
    names = {
        int(man["symbols"][n], 16): n
        for n in (
            "STR_INPUT_L",
            "STR_SKEL_L",
            "STR_INPUT_R",
            "STR_SKEL_R",
            "STR_POSE_RAW",
        )
    }
    create = r.calls[0]
    handle = struct.unpack(
        "<Q", r.uc.mem_read(int(man["symbols"]["STATE"], 16) + 8, 8)
    )[0]
    ok = (
        create[0] == "create"
        and create[1] == 0x1234
        and names.get(create[2]) == "STR_INPUT_R"
        and names.get(create[3]) == "STR_SKEL_R"
        and names.get(create[4][0]) == "STR_POSE_RAW"
        and create[4][1] == B.SKELETAL_TRACKING_LEVEL
        and create[4][2] == 0
        and create[4][3] == 31
        and handle == 0xDEADBEEF
    )
    if not ok:
        print("create stub did not call CreateSkeletonComponent correctly:", create)
        return False
    r.calls.clear()
    r.call(int(man["stubs"]["update"], 16), [CTRL, KEY6])
    ok = [c[0] for c in r.calls] == ["update", "update"] and all(
        c[1] == 0xDEADBEEF and len(c[3]) == 31 * 32 and c[2] in (0, 1) for c in r.calls
    )
    if not ok:
        print("update stub did not drive the skeleton:", r.calls)
        return False
    state = int(man["symbols"]["SCRATCH"], 16) + 0x300

    def translate(dp_mask):
        v2 = dp_mask & 0x105F
        if dp_mask & 0x80:
            v2 |= 0x20  # stick touch   -> v2 bit5
        if dp_mask & 0x20:
            v2 |= 0x80  # trigger touch -> v2 bit7
        return v2

    for dp_mask in (
        0x0000,
        0x0002,
        0x0008,
        0x0020,
        0x0080,
        0x0028,
        0x00A0,
        0x105F,
        0xE98D,
    ):
        rr = Run(True, v2_path)
        rr.prepare_globals()
        # the DP controller object numbers the hands 0 = left / 1 = right; the stub
        # hands v2's 1 = left / 2 = right on to the updater, so 1 -> 2 here.
        dp_hand = 1
        rr.uc.mem_write(
            int(man["symbols"]["STATE"], 16) + 8, struct.pack("<Q", 0xDEADBEEF)
        )
        rr.uc.mem_map(CTRL, 0x20000, unicorn.UC_PROT_ALL)
        rr.uc.mem_write(CTRL + 8, struct.pack("<I", dp_hand))
        rr.uc.mem_write(CTRL + 0x130, struct.pack("<I", 7))
        rr.uc.mem_write(CTRL + 0x138, struct.pack("<Q", 0x1234))
        rr.uc.mem_write(KEY6, struct.pack("<HBBBB", dp_mask, 0, 0, 128, 255))
        rr.uc.reg_write(UC_X86_REG_RBX, CTRL)
        rr.call(int(man["stubs"]["update"], 16), [CTRL, KEY6])
        via_stub = [c[3] for c in rr.calls]
        state = int(man["symbols"]["SCRATCH"], 16) + dp_hand * 0x300
        if struct.unpack("<I", rr.uc.mem_read(state + 0xE8, 4))[0] != dp_hand + 1:
            print(f"dp mask {dp_mask:#06x}: stub wrote the wrong hand index")
            return False
        rr.uc.mem_write(state, b"\0" * 0x300)
        rr.uc.mem_write(state + 0xE8, struct.pack("<I", dp_hand + 1))
        rr.uc.mem_write(state + 0x1C0, struct.pack("<Q", 0xDEADBEEF))
        rr.calls.clear()
        rr.call(
            updater_entry(True),
            [state, translate(dp_mask)],
            floats=((UC_X86_REG_XMM2, 128 / 255.0), (UC_X86_REG_XMM3, 255 / 255.0)),
        )
        direct = [c[3] for c in rr.calls]
        for a, b in zip(via_stub, direct):
            fa = struct.unpack(f"<{len(a) // 4}f", a)
            fb = struct.unpack(f"<{len(b) // 4}f", b)
            if max(abs(x - y) for x, y in zip(fa, fb)) > 1e-5:
                print(f"dp mask {dp_mask:#06x}: translation mismatch")
                return False
    print(
        "dynamic: create/update stubs work and the DP -> v2 mask translation is right"
    )
    return True


def main():
    global man, payload
    ap = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parents[3]
    ap.add_argument(
        "--v2",
        default=str(here / "temp/v2/app/openvr_driver/bin/win64/driver_pico.dll"),
    )
    ap.add_argument(
        "--payload",
        default=str(here / "src/windows/src/driver_patch/dp_skeleton_payload.bin"),
    )
    ap.add_argument(
        "--manifest",
        default=str(here / "src/windows/src/driver_patch/dp_skeleton_payload.json"),
    )
    ap.add_argument("--no-dynamic", action="store_true")
    a = ap.parse_args()
    man = json.loads(Path(a.manifest).read_text(encoding="utf-8"))
    payload = Path(a.payload).read_bytes()
    if not static_check(a.v2):
        return 1
    if a.no_dynamic:
        return 0
    return 0 if dynamic_check(a.v2) else 1


if __name__ == "__main__":
    sys.exit(main())
