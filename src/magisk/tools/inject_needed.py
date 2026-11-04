#!/usr/bin/env python3
"""给 libpxrstreamingservice.so 补一个 DT_NEEDED，把 picotouch_shim.so 带进加载列表。

原 .dynamic 没有空槽，所以新建一份 dynstr + dynamic 放到文件尾部，
再把最后一个 PT_LOAD 的 filesz 扩到覆盖它们。只改 ELF 装载信息，不改代码。

用法：python inject_needed.py <原始 .so> <输出 .so>
校验：llvm-readobj --dynamic-table <输出 .so> | grep picotouch_shim
"""

import struct
import sys

DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_STRSZ = 10
PT_LOAD = 1
PT_DYNAMIC = 2
SHT_DYNAMIC = 6

NEEDED = "picotouch_shim.so"


def align(value, alignment=8):
    return (value + alignment - 1) & ~(alignment - 1)


def segment_for(phdrs, addr):
    """返回 vaddr 落在 addr 的 PT_LOAD 项。"""
    return next(p for p in phdrs if p[1] == PT_LOAD and p[4] <= addr < p[4] + p[7])


def main(src, dst):
    with open(src, "rb") as f:
        data = bytearray(f.read())

    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]

    phdrs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        fields = struct.unpack_from("<IIQQQQQQ", data, off)
        phdrs.append([off, *fields])

    dyn = next(p for p in phdrs if p[1] == PT_DYNAMIC)
    load = max((p for p in phdrs if p[1] == PT_LOAD), key=lambda p: p[3])

    def file_to_vaddr(offset):
        return load[4] + (offset - load[3])

    entries = []
    pos = dyn[3]
    while True:
        tag, val = struct.unpack_from("<QQ", data, pos)
        pos += 16
        if tag == DT_NULL:
            break
        entries.append([tag, val])

    strtab_addr = next(val for tag, val in entries if tag == DT_STRTAB)
    strsz = next(val for tag, val in entries if tag == DT_STRSZ)
    strtab = segment_for(phdrs, strtab_addr)
    strtab_file = strtab[3] + strtab_addr - strtab[4]

    append = align(len(data))
    new_strtab = (
        bytes(data[strtab_file : strtab_file + strsz]) + NEEDED.encode() + b"\0"
    )
    strtab_vaddr = file_to_vaddr(append)

    dyn_off = align(append + len(new_strtab))
    new_entries = []
    for tag, val in entries:
        if tag == DT_STRTAB:
            new_entries.append([tag, strtab_vaddr])
        elif tag == DT_STRSZ:
            new_entries.append([tag, len(new_strtab)])
        else:
            new_entries.append([tag, val])
    new_entries.append([DT_NEEDED, strsz])
    new_entries.append([DT_NULL, 0])

    blob = bytearray()
    blob += new_strtab
    blob += b"\0" * (dyn_off - append - len(new_strtab))
    for tag, val in new_entries:
        blob += struct.pack("<QQ", tag, val)

    data += blob
    dyn_vaddr = file_to_vaddr(dyn_off)
    dyn_size = len(new_entries) * 16

    struct.pack_into(
        "<QQQQQQ",
        data,
        dyn[0] + 8,
        dyn_off,
        dyn_vaddr,
        dyn[5],
        dyn_size,
        dyn_size,
        dyn[8],
    )

    new_filesz = len(data) - load[3]
    new_memsz = max(load[7], new_filesz)
    struct.pack_into("<QQ", data, load[0] + 32, new_filesz, new_memsz)

    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize = struct.unpack_from("<H", data, 58)[0]
    e_shnum = struct.unpack_from("<H", data, 60)[0]
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if struct.unpack_from("<I", data, off + 4)[0] == SHT_DYNAMIC:
            struct.pack_into("<QQQ", data, off + 16, dyn_vaddr, dyn_off, dyn_size)

    with open(dst, "wb") as f:
        f.write(bytes(data))
    print(f"{dst}: NEEDED {NEEDED}, dynstr@0x{strtab_vaddr:x}, dynamic@0x{dyn_vaddr:x}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("[X] 用法：python inject_needed.py <原始 .so> <输出 .so>")
    main(sys.argv[1], sys.argv[2])
