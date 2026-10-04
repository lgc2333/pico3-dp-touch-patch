#!/data/data/com.termux/files/usr/bin/sh
# install.sh —— Termux 侧兜底装 kit（PC 侧 adbd 不是 root 时用；是 root 的话 PC 的 push.bat 会直接装好）。
# `termux-setup-storage` 后：sh /sdcard/Download/pico_touch/install.sh
# 只做两件事：把 /sdcard 上的 kit 覆盖式拷进 ~/pico_touch + 把短命令 dptouch 指过去（可重复跑）。
# 头显侧不再自己下依赖（frida-inject / picohaxx 由 PC 侧 get_deps.ps1 + push.bat 推过来）；
# 缺 adb 时 dptouch 第一次跑会自己 `pkg update`/`pkg upgrade` 并装 android-tools。
set -e
S=/sdcard/Download/pico_touch
D=$HOME/pico_touch

echo '[=] 1/2 装 kit 到 ~/pico_touch'
mkdir -p "$D"
cp -rf "$S/." "$D/"     # 用「./」是覆盖式拷贝：重复跑不会套娃成 ~/pico_touch/pico_touch
rm -f "$D/termux_touch.sh" "$D/launch.sh" "$D/wrapper.sh"   # 旧名迁移（2026-10-05 改名为 dptouch.sh；入口是 symlink，没有 wrapper 文件了）
chmod 755 "$D" "$D"/*.sh "$D"/*.bin 2>/dev/null || true   # 目录也要 755：shell 用户的 adb 只读看得到 kit（见 AGENTS 设备端）

echo '[=] 2/2 装短命令 dptouch'
mkdir -p "$PREFIX/bin"
# symlink 没问题，关键是**由 app 自己建**：这样才带 app 的 SELinux 类别（root 建的条目会让 app 连 stat 都 Permission denied）
ln -sf "$D/dptouch.sh" "$PREFIX/bin/dptouch" || {
    echo '[X] 建不了 symlink：多半是残留的旧条目（root 建的、SELinux 类别不对）'
    echo '    在 PC 上重跑 push.bat（它会先删再建），或先用 root 把那个条目删掉'
    exit 1
}

echo "[+] 装好了：$D"
echo "    以后开机在 Termux 里敲：dptouch"
