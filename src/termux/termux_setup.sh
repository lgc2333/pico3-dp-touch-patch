#!/data/data/com.termux/files/usr/bin/sh
# termux_setup.sh —— 一次性准备（在头显的 Termux 里跑）
#
# 纯本地方案**不需要 adb**，所以不用装 android-tools。
# 只需：授权存储访问 + 确认 /sdcard 上的文件可读。

set -e

SRC=/sdcard/Download/pico_touch

echo "=== 1) 授权存储访问 ==="
echo "（会弹系统授权框，点允许）"
termux-setup-storage || true
sleep 3

echo
echo "=== 2) 确认文件可读 ==="
ls -l "$SRC" || { echo "[X] 读不到 $SRC —— 存储授权没给？"; exit 1; }

echo
echo "=== 3) 确认 /data/local/tmp 里的工具就位（重启不丢）==="
ls -l /data/local/tmp/ | grep -E "picohaxx|frida-inject|hook.js|start_touch" || true

echo
echo "[✓] 准备完成。之后每次开机只需跑："
echo "    bash ~/termux_touch.sh"
echo
echo "[i] 说明：本方案完全不使用 adb —— 靠 picohaxx 自带的 root 执行能力，"
echo "    所以 picohaxx 重启 adbd 导致的无线 adb 断连也不影响。"
