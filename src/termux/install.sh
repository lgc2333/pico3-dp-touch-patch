#!/data/data/com.termux/files/usr/bin/sh
# install.sh —— 兜底安装（PC 侧 adbd 不是 root 时用；是 root 的话 PC 会直接装好，不用这个）
#   头显 Termux 里先 termux-setup-storage（弹窗点允许），再：
#       sh /sdcard/Download/pico_touch/install.sh
# 作用：把 /sdcard 上的 kit 覆盖式拷进 ~/pico_touch，并装好短命令 dptouch。可重复跑。
set -e
S=/sdcard/Download/pico_touch
D=$HOME/pico_touch
mkdir -p "$D"
cp -rf "$S/." "$D/"     # 用「/.」是覆盖式拷贝：重复跑不会套娃成 ~/pico_touch/pico_touch
chmod 755 "$D"/*.sh "$D"/*.bin 2>/dev/null || true
mkdir -p "$PREFIX/bin"
cp -f "$D/launch.sh" "$PREFIX/bin/dptouch"
chmod 755 "$PREFIX/bin/dptouch"
echo "[+] 装好了：$D"
echo "    以后开机在 Termux 里敲：dptouch"
