#!/bin/sh
# get_deps.sh —— 从上游自动拉取并准备依赖二进制（Linux / macOS / Termux）
#
# 产物（下载到本目录，被 .gitignore 忽略）：
#   src/termux/frida-inject        frida 16.7.19 · android-arm64（.xz 解压）
#   src/termux/picohaxx.neo3.bin   上游 picohaxx + Neo 3 适配补丁
#
# Neo 3 补丁（逐字节校验后原地改写）：
#   0x34b6  18B  '5.9.9-202408300028' → '202409100313' + 6×NUL
#   0x164ef9  1B  0xB0 → 0x50
#
# 依赖：curl、xz、dd（Termux：pkg install -y curl xz-utils coreutils）
# 用法：sh src/termux/get_deps.sh
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
INJ="$HERE/frida-inject"
HAX="$HERE/picohaxx.neo3.bin"

FVER=16.7.19
INJNAME="frida-inject-$FVER-android-arm64"
INJ_URLS="https://github.com/frida/frida/releases/download/$FVER/$INJNAME.xz https://ghfast.top/https://github.com/frida/frida/releases/download/$FVER/$INJNAME.xz"
HAX_MD5=734ddd6f8157378b2785183c5cfafa94
HAX_URLS="https://raw.githubusercontent.com/264312431/picohaxx/main/picohaxx https://ghfast.top/https://raw.githubusercontent.com/264312431/picohaxx/main/picohaxx"

command -v curl >/dev/null 2>&1 || { echo "[X] 需要 curl"; exit 1; }

TMP=$(mktemp -d 2>/dev/null || { d=/tmp/pico_deps.$$; mkdir -p "$d"; echo "$d"; })
trap 'rm -rf "$TMP"' EXIT

fetch() {  # fetch <out> <url...>
    out=$1; shift
    for u in "$@"; do
        echo "[*] 下载 $u"
        curl -fL --retry 3 --connect-timeout 15 -o "$out" "$u" && return 0
        echo "[!] 失败：$u"
    done
    return 1
}

md5of() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
    else md5 -q "$1"; fi
}

extract_xz() {  # <xz> <outfile>：依次尝试 xz / unxz / tar
    if command -v xz >/dev/null 2>&1; then xz -dc "$1" > "$2"; return $?; fi
    if command -v unxz >/dev/null 2>&1; then unxz -c "$1" > "$2"; return $?; fi
    if tar -xf "$1" -C "$TMP" 2>/dev/null; then mv -f "$TMP/$INJNAME" "$2"; return $?; fi
    return 1
}

# --- frida-inject ---
if [ -f "$INJ" ]; then
    echo "[=] frida-inject 已存在，跳过"
else
    fetch "$TMP/$INJNAME.xz" $INJ_URLS || { echo '[X] frida-inject 下载失败'; exit 1; }
    extract_xz "$TMP/$INJNAME.xz" "$INJ" || {
        echo '[X] 解压 .xz 失败：请安装 xz（Termux：pkg install -y xz-utils）'; exit 1; }
    chmod +x "$INJ"
    echo "[+] frida-inject -> $INJ"
fi

# --- picohaxx + Neo 3 补丁 ---
if [ -f "$HAX" ]; then
    echo "[=] picohaxx.neo3.bin 已存在，跳过"
else
    fetch "$TMP/picohaxx" $HAX_URLS || { echo '[X] picohaxx 下载失败'; exit 1; }
    md5=$(md5of "$TMP/picohaxx")
    if [ "$md5" != "$HAX_MD5" ]; then
        echo "[X] 上游 picohaxx md5 = $md5，预期 $HAX_MD5"
        echo "    上游已更新，补丁偏移需重新确认（见 docs/06-root.md）；已中止。"
        exit 1
    fi
    cp "$TMP/picohaxx" "$HAX"
    fw=$(dd if="$HAX" bs=1 skip=$((0x34b6)) count=18 2>/dev/null | tr -d '\0')
    [ "$fw" = "5.9.9-202408300028" ] || { echo "[X] 固件串不符：'$fw'；已中止。"; exit 1; }
    b=$(dd if="$HAX" bs=1 skip=$((0x164ef9)) count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$b" = "b0" ] || { echo "[X] 0x164ef9 = 0x$b（预期 0xb0）；已中止。"; exit 1; }
    printf '202409100313\0\0\0\0\0\0' | dd of="$HAX" bs=1 seek=$((0x34b6)) conv=notrunc 2>/dev/null
    printf '\x50'                     | dd of="$HAX" bs=1 seek=$((0x164ef9)) conv=notrunc 2>/dev/null
    echo "[+] picohaxx.neo3.bin 已生成（Neo 3 补丁已应用）"
fi

echo ""
echo "[✓] 依赖就绪："
ls -l "$INJ" "$HAX"
