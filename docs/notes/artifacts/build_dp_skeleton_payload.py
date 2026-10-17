#!/usr/bin/env python3
"""Build the DP-driver skeleton payload from the v2 driver DLL.

`patch_driver.ps1` appends this payload to `driver_pico.dll` as a new PE section
(`.pitouch`) and hooks two places in the driver.  The payload contains:

  * a verbatim copy of v2's skeleton code cluster (the 31-bone generator, the two
    pose tables it needs, the slerp helper and the per-controller skeleton
    updater), with every reference that leaves the cluster relocated;
  * the `.rdata` constants that cluster reads (not relocated by identity, copied);
  * two stubs: one that creates the `/input/skeleton/{left,right}` components,
    one that feeds the updater from the DP input-update path (it also translates
    the DP 16-bit key word into the v2 mask layout, see docs/notes/04_d-driver-skeleton.md);
  * an `acosf` implementation (DP statically links a CRT without `acosf`);
  * per-hand state: the component handles and the updater's scratch block.

Everything is position independent (RIP-relative only), so the OS may relocate
the image; the only absolute assumption is that the new section lands at the
driver's original `SizeOfImage` (`SECTION_RVA`), which `patch_driver.ps1` checks
before it writes anything.

Usage (needs the v2 driver DLL; both hashes are pinned below):

    uv run --with capstone --with keystone-engine --with pefile \\
        python docs/notes/artifacts/build_dp_skeleton_payload.py [v2_driver_pico.dll] [out_base]

Verification: `docs/notes/artifacts/dp_skeleton_payload_test.py` runs v2's updater
and the relocated copy side by side under Unicorn and compares the transforms,
`docs/notes/artifacts/dp_skeleton_image_test.py` drives the hook points of an
actually patched driver image.
"""

import argparse
import hashlib
import json
import struct
from pathlib import Path

import capstone
import keystone
import pefile

# ---------------------------------------------------------------- fixed facts

DP_BASE = 0x180000000
DP_MD5 = "9017439d560747678b4550fcf6726808"
SECTION_RVA = 0xAB000  # == DP's current SizeOfImage; verified by the patch script
SECTION_BASE = DP_BASE + SECTION_RVA

V2_SHA256 = "d851b7d1727b4f8daba769a60f4e8d44674857d962b5e6f40b32f7b7aed03418"
V2_MD5 = "e6d408b2590042c3c7f796b694ffc404"

# CreateSkeletonComponent's eSkeletalTrackingLevel.  v2 branches on the controller
# object's `+0x2E0`: that flag is its "hand-tracking build" switch -- the same flag
# makes it report the device as "Pico Hand" instead of "Pico Neo3/PICO 4 Controller"
# (sub_180016110).  So the plain controller variant (what DP drives) gets
# VRSkeletalTracking_Estimated, and only the hand-tracking variant gets Full.
SKELETAL_TRACKING_LEVEL = 0

# v2 code cluster: generator sub_1800316D0 .. tail of sub_180040080
SRC_START = DP_BASE + 0x316D0
SRC_END = DP_BASE + 0x402C3

# v2 -> DP symbol mapping for references that leave the cluster
SYMBOLS = {
    # jump thunks in v2's incremental-link thunk area -> the real function
    DP_BASE + 0x1604: ("blob", DP_BASE + 0x35DC0),  # pose table  A (sub_180001604)
    DP_BASE + 0x1A2D: (
        "blob",
        DP_BASE + 0x316D0,
    ),  # binder      (sub_180001A2D -> generator)
    DP_BASE + 0x1AB9: ("blob", DP_BASE + 0x40080),  # slerp       (sub_180001AB9)
    DP_BASE + 0x1FD7: ("blob", DP_BASE + 0x37860),  # pose table  B (sub_180001FD7)
    DP_BASE + 0x1992: ("blob", DP_BASE + 0x32360),  # pose blend helper
    # CRT / driver helpers that DP already has
    DP_BASE + 0x180C: ("abs", DP_BASE + 0x469B0),  # __security_check_cookie
    DP_BASE + 0x110E: ("abs", DP_BASE + 0x25110),  # driver log(fmt, ...)
    DP_BASE + 0x72B16: ("abs", DP_BASE + 0x70E70),  # sinf
    DP_BASE + 0x72B3A: ("acosf", None),  # acosf -> our own implementation
    DP_BASE + 0x72B40: ("abs", DP_BASE + 0x70900),  # sin
    # mutable globals
    DP_BASE + 0x99D80: ("abs", DP_BASE + 0x9A088),  # __security_cookie
    DP_BASE + 0x9BD10: ("abs", DP_BASE + 0xA2B40),  # cached IVRDriverInput pointer
    DP_BASE + 0x9BCB0: ("abs", DP_BASE + 0xA2B58),  # IVRDriverContext pointer
}

# DP code/globals the stubs talk to
DP_IVRINPUT_GLOBAL = DP_BASE + 0xA2B40
DP_DRVCTX_GLOBAL = DP_BASE + 0xA2B58
DP_LOG_FN = DP_BASE + 0x25110
DP_COS_FN = DP_BASE + 0x6FE80  # double cos
DP_SIN_FN = DP_BASE + 0x70900  # double sin
DP_CREATE_HOOK_SITE = DP_BASE + 0x17E86  # call sub_180025110 in the component creator
DP_CREATE_HOOK_NEXT = DP_BASE + 0x17E8B
DP_UPDATE_HOOK_SITE = DP_BASE + 0x19580  # entry of sub_180019580
DP_UPDATE_HOOK_NEXT = DP_BASE + 0x19585  # after mov r11,rsp / push rbp / push rdi

UPDATER_SRC = DP_BASE + 0x3FDA0  # v2's per-controller skeleton updater

# scratch block layout used by the transplanted updater (v2 field offsets)
SCRATCH_HAND_OFF = 0x0E8
SCRATCH_HANDLE_OFF = 0x1C0
SCRATCH_SIZE = 0x300

STR_IVRINPUT = b"IVRDriverInput_003\0"
STR_POSE_RAW = b"/pose/raw\0"
STR_INPUT_L = b"/input/skeleton/left\0"
STR_SKEL_L = b"/skeleton/hand/left\0"
STR_INPUT_R = b"/input/skeleton/right\0"
STR_SKEL_R = b"/skeleton/hand/right\0"

FP = {
    "ONE": 1.0,
    "MINUS_ONE": -1.0,
    "INV255": 1.0 / 255.0,
}
# acosf: double-precision A&S initial guess (the slerp in v2's skeleton code is
# ill-conditioned near acos(1), so a float-only polynomial is not accurate enough)
# acosf: acos(x) = 2*asin(sqrt((1-x)/2)) (x >= 0) / pi - 2*asin(sqrt((1+x)/2)) (x < 0),
# with asin(y) = y*Q(y) for y in [0, sqrt(1/2)].  v2's skeleton slerp divides by
# sin(acos(dot)), so the result has to be accurate right up to both ends of [-1, 1];
# a plain float polynomial (or a Newton form, which has a double root at acos(1))
# is not good enough there.  Q is a degree-16 Chebyshev fit, evaluated in double.
DP = {
    "D_ONE": 1.0,
    "D_HALF": 0.5,
    "D_PI": 3.141592653589793,
    "D_Q0": 1.0000000000052531,
    "D_Q1": -4.293073444482098e-09,
    "D_Q2": 0.1666672463283022,
    "D_Q3": -3.082528321936284e-05,
    "D_Q4": 0.07585824884591043,
    "D_Q5": -0.01441473003320024,
    "D_Q6": 0.2032611743613938,
    "D_Q7": -1.2043188465867756,
    "D_Q8": 6.551260216042541,
    "D_Q9": -25.686604557737432,
    "D_Q10": 74.33465441026061,
    "D_Q11": -157.8393111484994,
    "D_Q12": 243.34908235241306,
    "D_Q13": -265.1162972514271,
    "D_Q14": 193.78085046347562,
    "D_Q15": -85.40911050343243,
    "D_Q16": 17.23572072846801,
}

ALIGN = 16


def align(n, a=ALIGN):
    return (n + a - 1) // a * a


# ------------------------------------------------------------------ PE helper


class Image:
    def __init__(self, path):
        self.path = path
        self.pe = pefile.PE(path)
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        with open(path, "rb") as fh:
            self.raw = fh.read()
        self.sections = [
            (
                s.Name.rstrip(b"\0").decode(),
                self.base + s.VirtualAddress,
                max(s.Misc_VirtualSize, s.SizeOfRawData),
                s.PointerToRawData,
                s.SizeOfRawData,
            )
            for s in self.pe.sections
        ]

    def off(self, va):
        for _n, va0, size, ptr, rawsize in self.sections:
            if va0 <= va < va0 + size and va - va0 < rawsize:
                return ptr + (va - va0)
        raise KeyError(hex(va))

    def read(self, va, n):
        o = self.off(va)
        return self.raw[o : o + n]

    def section_of(self, va):
        for n, va0, size, _ptr, _rawsize in self.sections:
            if va0 <= va < va0 + size:
                return n
        return None


# ------------------------------------------------------------------- scanning


def scan_cluster(img, md):
    """Return (branches, riprefs) for the copied code range."""
    branches = []  # (insn_va, insn_size, target_va)
    riprefs = []  # (insn_va, insn_size, disp_off, target_va, access_size, is_lea)
    off = img.off(SRC_START)
    blob = img.raw[off : off + (SRC_END - SRC_START)]
    va = SRC_START
    while va < SRC_END:
        ins = next(md.disasm(blob[va - SRC_START : va - SRC_START + 15], va), None)
        if ins is None:
            raise SystemExit(f"lost sync at {hex(va)}")
        imm_size = 0
        for op in ins.operands:
            if op.type == capstone.x86.X86_OP_IMM and op.size:
                imm_size = max(imm_size, op.size)
        for op in ins.operands:
            if (
                op.type == capstone.x86.X86_OP_MEM
                and op.mem.base == capstone.x86.X86_REG_RIP
            ):
                disp_off = ins.size - imm_size - 4
                got = struct.unpack_from("<i", blob, va - SRC_START + disp_off)[0]
                if got != op.mem.disp:
                    raise SystemExit(f"disp mismatch at {hex(va)}")
                target = va + ins.size + op.mem.disp
                riprefs.append(
                    (va, ins.size, disp_off, target, op.size, ins.mnemonic == "lea")
                )
        if (
            ins.mnemonic
            in (
                "call",
                "jmp",
                "je",
                "jne",
                "jz",
                "jnz",
                "jg",
                "jge",
                "jl",
                "jle",
                "ja",
                "jae",
                "jb",
                "jbe",
                "js",
                "jns",
                "jo",
                "jno",
                "jp",
                "jnp",
                "jrcxz",
            )
            and ins.operands
            and ins.operands[0].type == capstone.x86.X86_OP_IMM
        ):
            t = ins.operands[0].imm
            if not (SRC_START <= t < SRC_END):
                branches.append((va, ins.size, t))
        va += ins.size
    if va != SRC_END:
        raise SystemExit("cluster end mismatch")
    return blob, branches, riprefs


def const_ranges(img, riprefs):
    """Work out which .rdata bytes the cluster needs, and how big they are."""
    ranges = []
    seen = {}
    for _va, _size, _disp, target, access, is_lea in riprefs:
        if target in SYMBOLS:
            continue
        sec = img.section_of(target)
        if sec != ".rdata":
            raise SystemExit(f"unexpected rip target {hex(target)} in {sec}")
        size = access
        if is_lea:
            # address-taken: it is a C string -> run to the NUL
            size = 0
            while size < 512:
                if img.read(target + size, 1) == b"\0":
                    size += 1
                    break
                size += 1
            if size >= 512:
                raise SystemExit(f"string at {hex(target)} too long")
        elif size == 0:
            size = 4
        # widen to 16 bytes so neighbouring constants of the same item travel along
        lo = target & ~0xF
        hi = align(target + size)
        old = seen.get(target)
        if old is None or old < hi:
            seen[target] = hi
        ranges.append((lo, hi))
    # merge
    ranges.sort()
    merged = []
    for lo, hi in ranges:
        if merged and lo <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return merged


# --------------------------------------------------------------------- layout


def build(v2_path, out_bin, out_json):
    img = Image(v2_path)
    if hashlib.sha256(img.raw).hexdigest() != V2_SHA256:
        raise SystemExit("v2 driver DLL sha256 mismatch - refusing to build")
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True
    blob, branches, riprefs = scan_cluster(img, md)
    consts = const_ranges(img, riprefs)

    payload = bytearray()
    # --- 1. relocated code cluster ---
    blob_off = 0
    payload += blob
    blob_base = SECTION_BASE + blob_off

    def blob_addr(va):
        return blob_base + (va - SRC_START)

    # --- 2. constants ---
    payload += b"\0" * (align(len(payload)) - len(payload))
    const_span = {}
    for lo, hi in consts:
        payload += b"\0" * (align(len(payload)) - len(payload))
        const_span[lo] = (SECTION_BASE + len(payload), hi - lo)
        payload += img.read(lo, hi - lo)

    def const_addr(va):
        for lo, (new_lo, size) in const_span.items():
            if lo <= va < lo + size:
                return new_lo + (va - lo)
        raise SystemExit(f"no const for {hex(va)}")

    # --- 3. strings / floats / state ---
    payload += b"\0" * (align(len(payload)) - len(payload))
    sym = {}

    def put(name, data, alignment=ALIGN):
        payload.extend(b"\0" * (align(len(payload), alignment) - len(payload)))
        sym[name] = SECTION_BASE + len(payload)
        payload.extend(data)

    put("STR_IVRINPUT", STR_IVRINPUT)
    put("STR_POSE_RAW", STR_POSE_RAW)
    put("STR_INPUT_L", STR_INPUT_L)
    put("STR_SKEL_L", STR_SKEL_L)
    put("STR_INPUT_R", STR_INPUT_R)
    put("STR_SKEL_R", STR_SKEL_R)
    for k, v in FP.items():
        put("FP_" + k, struct.pack("<f", v), 4)
    for k, v in DP.items():
        put("DP_" + k, struct.pack("<d", v), 8)
    state_off = align(len(payload))
    payload.extend(b"\0" * (state_off - len(payload)))
    sym["STATE"] = SECTION_BASE + state_off
    sym["SCRATCH"] = SECTION_BASE + state_off + 0x20
    payload.extend(b"\0" * (0x20 + 2 * SCRATCH_SIZE))

    # --- 4. stubs ---
    ks = keystone.Ks(keystone.KS_ARCH_X86, keystone.KS_MODE_64)

    updater_addr = blob_addr(UPDATER_SRC)

    def asm_stub(code, addr, ripref_targets):
        enc, _n = ks.asm(code, addr=addr)
        if enc is None:
            raise SystemExit("keystone failed")
        buf = bytearray(enc)
        # patch the RIP-relative placeholders in order
        hits = []
        for ins in md.disasm(bytes(buf), addr):
            for op in ins.operands:
                if (
                    op.type == capstone.x86.X86_OP_MEM
                    and op.mem.base == capstone.x86.X86_REG_RIP
                ):
                    hits.append(ins)
                    break
        if len(hits) != len(ripref_targets):
            raise SystemExit(
                f"rip placeholder count {len(hits)} != {len(ripref_targets)}"
            )
        for ins, tgt in zip(hits, ripref_targets):
            noff = ins.address - addr
            disp_off = ins.size - 4
            # re-check: our placeholders have no immediate operands
            for op in ins.operands:
                if op.type == capstone.x86.X86_OP_IMM and op.size:
                    disp_off = ins.size - op.size - 4
            new = tgt - (ins.address + ins.size)
            struct.pack_into("<i", buf, noff + disp_off, new)
        return bytes(buf)

    # CreateSkeletonComponent's eSkeletalTrackingLevel.  v2 passes Full on the path
    # that drives the skeleton itself; with Estimated applications treat the poses
    # as guesses and pose the fingers from the touch/click components instead
    # (docs/notes/04_d-driver-skeleton.md).
    create_tmpl = f"""
create_stub:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    sub rsp, 0x60
    mov eax, dword ptr [rbx+8]
    cmp eax, 1
    ja .c_out
    lea r9, [rip + 0x11111111]
    mov r11, qword ptr [r9+rax*8]
    test r11, r11
    jnz .c_out
    mov rcx, qword ptr [rip + 0x11111111]
    test rcx, rcx
    jnz .c_have
    mov r11d, eax
    mov rcx, qword ptr [rip + 0x22222222]
    lea r8, [r9+0x10]
    lea rdx, [rip + 0x11111111]
    mov rax, qword ptr [rcx]
    call qword ptr [rax]
    mov qword ptr [rip + 0x22222222], rax
    mov rcx, rax
    lea r9, [rip + 0x11111111]
    lea r8, [r9+0x10]
    mov eax, r11d
.c_have:
    test rcx, rcx
    jz .c_out
    lea r11, [r9+rax*8]
    mov qword ptr [rsp+0x40], r11
    mov dword ptr [rsp+0x38], 31
    mov dword ptr [rsp+0x30], 0
    mov dword ptr [rsp+0x28], {SKELETAL_TRACKING_LEVEL}
    lea r11, [rip + 0x11111111]
    mov qword ptr [rsp+0x20], r11
    test eax, eax
    jnz .c_right
    lea r8, [rip + 0x11111111]
    lea r9, [rip + 0x11111111]
    jmp .c_go
.c_right:
    lea r8, [rip + 0x11111111]
    lea r9, [rip + 0x11111111]
.c_go:
    mov rdx, qword ptr [rbx+0x138]
    mov rax, qword ptr [rcx]
    call qword ptr [rax+0x28]
.c_out:
    mov rcx, qword ptr [rsp+0x88]
    call {DP_LOG_FN}
    add rsp, 0x60
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret
"""

    create_addr = SECTION_BASE + align(len(payload))
    create_targets = [
        sym["STATE"],  # lea r9, &state
        DP_IVRINPUT_GLOBAL,  # mov rcx, [iface]
        DP_DRVCTX_GLOBAL,  # mov rcx, [ctx]
        sym["STR_IVRINPUT"],  # lea rdx, name
        DP_IVRINPUT_GLOBAL,  # store fetched iface
        sym["STATE"],  # lea r9, &state (reload after the call)
        sym["STR_POSE_RAW"],  # base pose path
        sym["STR_INPUT_L"],
        sym["STR_SKEL_L"],
        sym["STR_INPUT_R"],
        sym["STR_SKEL_R"],
    ]
    create_code = asm_stub(create_tmpl, create_addr, create_targets)
    payload.extend(b"\0" * (create_addr - (SECTION_BASE + len(payload))))
    payload.extend(create_code)

    # v2 numbers the hands 1 = left / 2 = right and its updater only tests `== 1`;
    # the DP controller object carries 0 = left / 1 = right, so the index has to be
    # shifted up -- otherwise both hands get the other hand's mirrored pose, which
    # also makes the runtime read every finger backwards (docs/notes/04_d-driver-skeleton.md).
    update_tmpl = f"""
update_stub:
    pushfq
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    sub rsp, 0x48
    cmp dword ptr [rcx+0x130], -1
    je .u_out
    mov eax, dword ptr [rcx+8]
    cmp eax, 1
    ja .u_out
    lea r10, [rip + 0x11111111]
    mov r11, qword ptr [r10+rax*8]
    test r11, r11
    jz .u_out
    movzx r8d, byte ptr [rdx+4]
    movzx r9d, byte ptr [rdx+5]
    cvtsi2ss xmm2, r8d
    mulss xmm2, dword ptr [rip + 0x11111111]
    cvtsi2ss xmm3, r9d
    mulss xmm3, dword ptr [rip + 0x11111111]
    movzx edx, word ptr [rdx]
    mov r8d, edx
    and r8d, 0x105F
    mov r9d, edx
    and r9d, 0x80
    shr r9d, 2
    or r8d, r9d
    mov r9d, edx
    and r9d, 0x20
    shl r9d, 2
    or r8d, r9d
    mov edx, r8d
    lea rcx, [rip + 0x11111111]
    mov r8d, eax
    imul r8d, r8d, 0x300
    add rcx, r8
    lea r8d, [rax + 1]
    mov dword ptr [rcx+0xE8], r8d
    mov qword ptr [rcx+0x1C0], r11
    call {updater_addr}
.u_out:
    add rsp, 0x48
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    popfq
    mov r11, rsp
    push rbp
    push rdi
    jmp {DP_UPDATE_HOOK_NEXT}
"""

    update_addr = SECTION_BASE + align(len(payload))
    update_targets = [
        sym["STATE"],
        sym["FP_INV255"],
        sym["FP_INV255"],
        sym["SCRATCH"],
    ]
    update_code = asm_stub(update_tmpl, update_addr, update_targets)
    payload.extend(b"\0" * (update_addr - (SECTION_BASE + len(payload))))
    payload.extend(update_code)

    # shared Horner chain for Q(y); y is in xmm3, the result lands in xmm0
    horner = "\n".join(
        ["    movsd xmm0, qword ptr [rip + 0x11111111]"]
        + [
            "    mulsd xmm0, xmm3\n    addsd xmm0, qword ptr [rip + 0x11111111]"
            for _ in range(16)
        ]
    )
    horner_targets = [sym["DP_D_Q16"]] + [sym[f"DP_D_Q{i}"] for i in range(15, -1, -1)]

    acosf_tmpl = (
        """
acosf_impl:
    minss xmm0, dword ptr [rip + 0x11111111]
    maxss xmm0, dword ptr [rip + 0x11111111]
    cvtss2sd xmm1, xmm0
    xorpd xmm2, xmm2
    comisd xmm1, xmm2
    jb .neg
    movsd xmm3, qword ptr [rip + 0x11111111]
    subsd xmm3, xmm1
    mulsd xmm3, qword ptr [rip + 0x11111111]
    sqrtsd xmm3, xmm3
"""
        + horner
        + """
    mulsd xmm0, xmm3
    addsd xmm0, xmm0
    cvtsd2ss xmm0, xmm0
    ret
.neg:
    movsd xmm3, qword ptr [rip + 0x11111111]
    addsd xmm3, xmm1
    mulsd xmm3, qword ptr [rip + 0x11111111]
    sqrtsd xmm3, xmm3
"""
        + horner
        + """
    mulsd xmm0, xmm3
    addsd xmm0, xmm0
    movsd xmm4, qword ptr [rip + 0x11111111]
    subsd xmm4, xmm0
    cvtsd2ss xmm0, xmm4
    ret
"""
    )
    acosf_addr = SECTION_BASE + align(len(payload))
    acosf_targets = (
        [sym["FP_ONE"], sym["FP_MINUS_ONE"], sym["DP_D_ONE"], sym["DP_D_HALF"]]
        + horner_targets
        + [sym["DP_D_ONE"], sym["DP_D_HALF"]]
        + horner_targets
        + [sym["DP_D_PI"]]
    )
    acosf_code = asm_stub(acosf_tmpl, acosf_addr, acosf_targets)
    payload.extend(b"\0" * (acosf_addr - (SECTION_BASE + len(payload))))
    payload.extend(acosf_code)

    # --- 5. relocate the code cluster ---
    def fix_branch(va, size, target):
        entry = SYMBOLS.get(target)
        if entry is None:
            raise SystemExit(f"unmapped branch target {hex(target)}")
        kind, dest = entry
        if kind == "blob":
            new_target = blob_addr(dest)
        elif kind == "acosf":
            new_target = acosf_addr
        else:
            new_target = dest
        noff = va - SRC_START + size - 4
        rel = new_target - (blob_addr(va) + size)
        struct.pack_into("<i", payload, noff, rel)

    for va, size, target in branches:
        fix_branch(va, size, target)

    for va, size, disp_off, target, _access, _is_lea in riprefs:
        if target in SYMBOLS:
            kind, dest = SYMBOLS[target]
            if kind == "blob":
                new_target = blob_addr(dest)
            elif kind == "acosf":
                new_target = acosf_addr
            else:
                new_target = dest
        else:
            new_target = const_addr(target)
        new_disp = new_target - (blob_addr(va) + size)
        struct.pack_into("<i", payload, va - SRC_START + disp_off, new_disp)

    # --- 6. patched call sites in DP ---
    def rel32(site, target):
        return target - (site + 5)

    create_site_rva = DP_CREATE_HOOK_SITE - DP_BASE
    update_site_rva = DP_UPDATE_HOOK_SITE - DP_BASE
    # original bytes in the shipped driver_pico.dll (md5 9017439d...); the patch
    # script verifies them again before it writes anything.
    orig_call = bytes.fromhex("e885d20000")
    orig_upd = bytes.fromhex("4c8bdc5557")
    if orig_call[0] != 0xE8 or orig_upd != b"\x4c\x8b\xdc\x55\x57":
        raise SystemExit("unexpected original bytes at a hook site")

    patches = [
        {
            "rva": create_site_rva,
            "old": orig_call.hex(),
            "new": (
                b"\xe8" + struct.pack("<i", rel32(DP_CREATE_HOOK_SITE, create_addr))
            ).hex(),
            "what": "component creator -> create skeleton component",
        },
        {
            "rva": update_site_rva,
            "old": orig_upd.hex(),
            "new": (
                b"\xe9" + struct.pack("<i", rel32(DP_UPDATE_HOOK_SITE, update_addr))
            ).hex(),
            "what": "input update -> drive the skeleton",
        },
    ]

    manifest = {
        "source": {
            "v2_sha256": V2_SHA256,
            "v2_md5": V2_MD5,
            "cluster": [hex(SRC_START), hex(SRC_END)],
        },
        "dp": {"base": DP_BASE, "md5": DP_MD5},
        "section": {
            "rva": SECTION_RVA,
            "name": ".pitouch",
            "declared_size": align(len(payload), 0x1000),
        },
        "payload_sha256": hashlib.sha256(bytes(payload)).hexdigest(),
        "payload_size": len(payload),
        "symbols": {k: hex(v) for k, v in sym.items()},
        "stubs": {
            "create": hex(create_addr),
            "update": hex(update_addr),
            "acosf": hex(acosf_addr),
        },
        "patches": patches,
        "const_span": {hex(k): [hex(v[0]), v[1]] for k, v in const_span.items()},
    }
    Path(out_bin).write_bytes(bytes(payload))
    Path(out_json).write_text(json.dumps(manifest, indent=2) + "\n", newline="\n")
    print(f"payload {len(payload)} bytes -> {out_bin}")
    print(f"  create_stub  {hex(create_addr)}")
    print(f"  update_stub  {hex(update_addr)}")
    print(f"  acosf_impl   {hex(acosf_addr)}")
    print(f"  updater copy {hex(updater_addr)}")
    print(f"  branches fixed {len(branches)}, rip refs fixed {len(riprefs)}")
    print(
        f"  const groups {len(const_span)} spanning {sum(v[1] for v in const_span.values())} bytes"
    )


REPO = Path(__file__).resolve().parents[3]  # docs/notes/artifacts/ -> repo root
DEFAULT_V2 = REPO / "temp/v2/app/openvr_driver/bin/win64/driver_pico.dll"
DEFAULT_OUT = REPO / "src/windows/src/driver_patch/dp_skeleton_payload"

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="build the DP skeleton payload")
    ap.add_argument(
        "v2_dll", nargs="?", default=str(DEFAULT_V2), help="v2 的 driver_pico.dll"
    )
    ap.add_argument(
        "out_base", nargs="?", default=str(DEFAULT_OUT), help="输出基名（.bin/.json）"
    )
    a = ap.parse_args()
    build(a.v2_dll, a.out_base + ".bin", a.out_base + ".json")
